# omi-ocr-helper.py — LOCAL ADAPT (XiaoWo): a drop-in replacement for the native
# win-ocr-helper.exe that speaks the SAME stdio frame protocol
# ([uint32 LE length][1 byte opcode][payload] -> [uint32 LE length][UTF-8 JSON])
# but runs RapidOCR (PP-OCR, ONNX) instead of Windows.Media.Ocr, whose zh
# recognizer produces spaced-out, garbled text on dense UI screens.
#
# Wire contract (mirrors win-ocr-helper/Program.cs exactly):
#   opcode 1 = OCR     payload = JPEG bytes
#     -> {"ok":true,"fullText":"...","lines":[{text,x,y,w,h,confidence}]}
#        or {"ok":false,"code":"DECODE_FAILED|HELPER_ERROR","message":"..."}
#   opcode 2 = WINDOW  payload = empty
#     -> {"app":"...","title":"...","pid":123,"processName":"..."}
#
# Enabled via OMI_OCR_HELPER_CMD (JSON array command line) — see
# src/main/ocr/helperProcess.ts. Requires: pip install rapidocr-onnxruntime.
#
# NOTE ON STDOUT: fd 1 is the protocol channel. Anything a library prints to
# stdout (onnxruntime warnings, cv2 noise) would desync the frame stream, so we
# dup the real fd 1 aside and repoint fd 1 at the devnull BEFORE importing the
# heavy libs; all protocol writes go through the saved descriptor.

import os
import sys

_real_stdout = os.dup(1)
_devnull = os.open(os.devnull, os.O_WRONLY)
os.dup2(_devnull, 1)  # fd 1 → devnull; libraries can print freely, we don't care
os.close(_devnull)

import ctypes
import json
import struct
from ctypes import wintypes

# LOCAL ADAPT (XiaoWo): bound ONNX Runtime to 6 intra-op threads — the default
# (every logical core) pegged the whole machine for the entire backlog drain.
# Applied by patching InferenceSession so we reach the sessions RapidOCR builds
# internally without patching the library itself.
import onnxruntime as ort

_orig_session_init = ort.InferenceSession.__init__


def _patched_session_init(self, *args, **kwargs):
    options = kwargs.pop("sess_options", None) or ort.SessionOptions()
    if options.intra_op_num_threads <= 0:
        options.intra_op_num_threads = 6
    options.inter_op_num_threads = 1
    kwargs["sess_options"] = options
    return _orig_session_init(self, *args, **kwargs)


ort.InferenceSession.__init__ = _patched_session_init

import cv2
import numpy as np
from rapidocr_onnxruntime import RapidOCR

engine = RapidOCR()

MAX_FRAME_BYTES = 64 * 1024 * 1024


def run_ocr(jpeg: bytes) -> dict:
    img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return {"ok": False, "code": "DECODE_FAILED", "message": "cv2.imdecode returned None"}
    h, w = img.shape[:2]
    result, _elapse = engine(img)
    lines = []
    texts = []
    confs = []
    for row in result or []:
        try:
            box, text, score = row[0], row[1], float(row[2])
        except (ValueError, IndexError, TypeError):
            continue  # malformed row — skip, never desync the protocol
        if not isinstance(box, (list, tuple)) or len(box) < 2:
            continue
        xs = [float(p[0]) for p in box]
        ys = [float(p[1]) for p in box]
        lines.append(
            {
                "text": text,
                "x": min(xs) / w,
                "y": min(ys) / h,
                "w": (max(xs) - min(xs)) / w,
                "h": (max(ys) - min(ys)) / h,
                "confidence": score,
            }
        )
        texts.append(text)
        confs.append(score)
    full_text = "\n".join(texts)
    confidence = sum(confs) / len(confs) if confs else 0.0
    return {"ok": True, "fullText": full_text, "lines": lines, "confidence": confidence}


def run_window() -> dict:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    hwnd = user32.GetForegroundWindow()
    length = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(max(1, length + 1))
    user32.GetWindowTextW(hwnd, buf, length + 1)
    pid_val = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid_val))
    pid = pid_val.value
    process_name = ""
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if handle:
        size = wintypes.DWORD(1024)
        exe_buf = ctypes.create_unicode_buffer(1024)
        if kernel32.QueryFullProcessImageNameW(handle, 0, exe_buf, ctypes.byref(size)):
            base = os.path.basename(exe_buf.value)
            process_name = os.path.splitext(base)[0]
        kernel32.CloseHandle(handle)
    # Match the C# helper's app casing: first char upper, rest untouched.
    app = process_name[:1].upper() + process_name[1:] if process_name else ""
    return {"app": app or process_name, "title": buf.value, "pid": pid, "processName": process_name}


def emit(payload: dict) -> None:
    out = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    os.write(_real_stdout, struct.pack("<I", len(out)) + out)


def main() -> int:
    stdin = sys.stdin.buffer
    while True:
        header = stdin.read(4)
        if len(header) < 4:
            return 0  # EOF — parent closed the pipe
        (length,) = struct.unpack("<I", header)
        if length == 0:
            continue
        if length > MAX_FRAME_BYTES:
            return 1  # desync — exit so the parent restarts clean
        body = stdin.read(length)
        if len(body) < length:
            return 0
        opcode = body[0]
        payload = body[1:]
        try:
            if opcode == 1:
                response = run_ocr(payload)
            elif opcode == 2:
                response = run_window()
            else:
                response = {"ok": False, "code": "HELPER_ERROR", "message": f"unknown opcode {opcode}"}
        except Exception as e:  # noqa: BLE001 — keep the loop alive like the C# helper
            response = {"ok": False, "code": "HELPER_ERROR", "message": str(e)}
        emit(response)


if __name__ == "__main__":
    sys.exit(main())
