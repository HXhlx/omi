from datetime import datetime, timezone
from typing import List, Optional

from pydantic import BaseModel, Field
from pydantic import field_validator
from utils.model_text import DisplayClock, format_elapsed, format_instant


class ConversationPhoto(BaseModel):
    id: Optional[str] = None
    # Legacy captures carry inline pixels.  Conversation-lifetime frame
    # evidence carries an opaque GCS reference instead; ambient pixels never
    # enter this model.
    base64: str
    storage_id: Optional[str] = None
    content_type: Optional[str] = None
    description: Optional[str] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    discarded: bool = False
    data_protection_level: Optional[str] = None

    @field_validator('storage_id')
    @classmethod
    def validate_storage_id(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        value = value.strip()
        if not value or '/' in value or '\\' in value or value.startswith(('http:', 'https:')):
            raise ValueError('storage_id must be an opaque owner-scoped identifier')
        return value

    @field_validator('content_type')
    @classmethod
    def validate_content_type(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        value = value.strip().lower()
        if not value.startswith('image/') or len(value) > 100:
            raise ValueError('content_type must be an image media type')
        return value

    @staticmethod
    def photos_as_string(
        photos: List['ConversationPhoto'],
        include_timestamps: bool = False,
        *,
        started_at: Optional[datetime] = None,
        clock: Optional[DisplayClock] = None,
    ) -> str:
        if not photos:
            return 'None'
        descriptions: list[str] = []
        for p in photos:
            if p.description and p.description.strip():
                timestamp_str = ''
                if include_timestamps:
                    if started_at is not None:
                        timestamp_str = f'[{format_elapsed((p.created_at - started_at).total_seconds())}] '
                    elif clock is not None:
                        timestamp_str = f'[{format_instant(p.created_at, clock)}] '
                    else:
                        timestamp_str = f"[{p.created_at.strftime('%H:%M:%S')}] "
                kind = ''
                # A recorded chest-camera segment keyframe: labels the item as a clip
                # keyframe so the model reads "segment start", not a lone still.
                content_type = (p.content_type or '').lower()
                if 'chest-segment' in content_type:
                    kind = ' (recorded segment keyframe)'
                descriptions.append(f'- {timestamp_str}"{p.description}"{kind}')

        if not descriptions:
            return 'None'
        return '\n'.join(descriptions)

    @staticmethod
    def photos_as_aligned_string(
        photos: List['ConversationPhoto'],
        segments: List[dict],
        *,
        started_at: Optional[datetime] = None,
        clock: Optional[DisplayClock] = None,
        segment_window: float = 15.0,
    ) -> str:
        """Photos and transcript sentences on one elapsed timeline.

        For each photo (or recorded-segment keyframe) the sentence whose
        [start, end] window contains the photo's capture offset is quoted next
        to its description, as ``[+0:12:30] "desc" — then: "sentence text"``.
        A photo outside every window is rendered with no sentence (the model
        sees exactly what was said nowhere near it, not a guess).

        ``segments`` are transcript segment dicts with ``start``/``end`` in
        seconds from the conversation start and a ``text``. When
        ``started_at`` is None (offsets unknown), the photo renders with its
        wall-clock only and no sentence is attempted.
        """
        if not photos:
            return 'None'
        if started_at is None:
            return ConversationPhoto.photos_as_string(photos, include_timestamps=True, clock=clock)
        windows: list[tuple[float, float, str]] = []
        for seg in segments:
            try:
                start = float(seg.get('start'))
                end = float(seg.get('end'))
            except (TypeError, ValueError):
                continue
            text = str(seg.get('text') or '').strip()
            if text:
                windows.append((start, end, text))

        descriptions: list[str] = []
        for p in photos:
            if not (p.description and p.description.strip()):
                continue
            offset = (p.created_at - started_at).total_seconds()
            # Sentence containing the capture instant wins; a segment keyframe
            # may fall in a pause, then the nearest sentence within
            # segment_window seconds makes the pair explicit instead of silent.
            matched: Optional[tuple[float, str]] = None
            for start, end, text in windows:
                if start <= offset <= end:
                    matched = (offset, text)
                    break
            if matched is None:
                nearest: Optional[tuple[float, str]] = None
                for start, end, text in windows:
                    distance = min(abs(offset - start), abs(offset - end))
                    if distance <= segment_window and (nearest is None or distance < nearest[0]):
                        nearest = (distance, text)
                if nearest is not None:
                    matched = (offset, nearest[1])
            sentence = f' — then: "{matched[1]}"' if matched is not None else ''
            kind = ' (recorded segment keyframe)' if 'chest-segment' in (p.content_type or '').lower() else ''
            descriptions.append(f'- [{format_elapsed(offset)}] "{p.description}"{kind}{sentence}')

        if not descriptions:
            return 'None'
        return '\n'.join(descriptions)
