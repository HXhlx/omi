"""Sentence-level alignment of chest-camera photos against transcript segments.

Covers ``ConversationPhoto.photos_as_aligned_string``: the capture instant is
anchored to the sentence whose [start, end] window contains it, a pause falls
back to the nearest sentence within the window, and a photo far from every
sentence renders with no sentence at all (never a guess).
"""

from datetime import datetime, timedelta, timezone

import pytest

from models.conversation_photo import ConversationPhoto

STARTED_AT = datetime(2026, 11, 27, 10, 0, 0, tzinfo=timezone.utc)


def photo(description: str, offset_seconds: float, content_type: str = 'image/jpeg') -> ConversationPhoto:
    return ConversationPhoto(
        base64='abc',
        description=description,
        content_type=content_type,
        created_at=STARTED_AT + timedelta(seconds=offset_seconds),
    )


SEGMENTS = [
    {'start': 0.0, 'end': 4.0, 'text': 'hello there'},
    {'start': 6.0, 'end': 10.0, 'text': 'lets talk about the plan'},
    {'start': 30.0, 'end': 36.0, 'text': 'the whiteboard shows the roadmap'},
]


def test_photo_inside_sentence_window_quotes_that_sentence():
    photos = [photo('a whiteboard', 32.0)]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, SEGMENTS, started_at=STARTED_AT)
    assert '[+0:00:32]' in rendered
    assert '"a whiteboard"' in rendered
    assert 'the whiteboard shows the roadmap' in rendered


def test_photo_in_pause_binds_nearest_sentence_within_window():
    # 12s sits in the pause between sentence 2 (ends 10s) and sentence 3 (30s).
    photos = [photo('a slide', 12.0)]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, SEGMENTS, started_at=STARTED_AT)
    assert 'lets talk about the plan' in rendered


def test_photo_far_from_every_sentence_renders_without_sentence():
    photos = [photo('an empty room', 90.0)]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, SEGMENTS, started_at=STARTED_AT)
    assert 'an empty room' in rendered
    assert 'then:' not in rendered


def test_segment_keyframe_is_labelled():
    photos = [photo('a keyframe', 32.0, content_type='image/jpeg;chest-segment')]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, SEGMENTS, started_at=STARTED_AT)
    assert '(recorded segment keyframe)' in rendered


def test_no_started_at_falls_back_to_wall_clock():
    photos = [photo('a dog', 30.0)]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, SEGMENTS, started_at=None)
    # photos_as_string fallback: wall-clock rendering, no sentence attempt.
    assert '"a dog"' in rendered
    assert 'then:' not in rendered


def test_no_photos_and_no_descriptions():
    assert ConversationPhoto.photos_as_aligned_string([], SEGMENTS, started_at=STARTED_AT) == 'None'
    undescribed = [ConversationPhoto(base64='abc', description=None, created_at=STARTED_AT)]
    assert ConversationPhoto.photos_as_aligned_string(undescribed, SEGMENTS, started_at=STARTED_AT) == 'None'


@pytest.mark.parametrize('malformed', [{'start': None, 'end': 2.0, 'text': 'x'}, {'text': 'no bounds'}, {}])
def test_malformed_segments_are_skipped_not_fatal(malformed):
    photos = [photo('a dog', 30.0)]
    segments = [malformed, {'start': 28.0, 'end': 34.0, 'text': 'hello'}]
    rendered = ConversationPhoto.photos_as_aligned_string(photos, segments, started_at=STARTED_AT)
    assert 'hello' in rendered
