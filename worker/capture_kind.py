"""Capture-session provenance is untrusted and never grants action permission."""
import re

def capture_kind(meta):
    name = meta.get('name', '')
    kind = meta.get('properties', {}).get('captureKind')
    if kind == 'dictated_note' and re.fullmatch(r'personal-capture-note-[a-f0-9-]{36}\.m4a', name):
        return kind
    if kind == 'note_interrupted' and re.fullmatch(r'personal-capture-note-draft-[a-f0-9-]{36}\.m4a', name):
        return kind
    return 'ambient_audio'
