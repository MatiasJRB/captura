"""Read-only record discovery and escaped, offline viewer export."""
import hashlib
import html
import json
from pathlib import Path
import shutil
from string import Template
from worker import SafeError, identifier, MAX_AUDIO

MAX_RECORD = 8 * 1024 * 1024


def read(root, item_id):
    root = Path(root).expanduser().resolve()
    item = root / identifier(item_id)
    if item.is_symlink() or not item.is_dir():
        raise SafeError('record_not_found')
    path = item / 'record.json'
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_RECORD:
        raise SafeError('invalid_record_file')
    try:
        data = json.loads(path.read_text())
        if (data.get('schema_version') != 1 or data.get('id') != item_id
                or data.get('review_only') is not True
                or data.get('speaker_verified') is not False
                or data.get('state') not in ('needs_review', 'no_speech_detected')
                or not isinstance(data['transcript']['text'], str)
                or not isinstance(data['transcript']['segments'], list)):
            raise ValueError()
        previous_start = -1
        for segment in data['transcript']['segments']:
            start, end = segment['start_ms'], segment['end_ms']
            if (type(start) is not int or type(end) is not int or start < 0 or end < start
                    or start < previous_start or not isinstance(segment['text'], str)):
                raise ValueError()
            previous_start = start
        original = data['original']
        if original['path'] not in ('original.m4a', None):
            raise ValueError()
        if original['path'] is not None:
            digest = original['sha256']
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
                raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise SafeError('invalid_record_schema') from None
    return data


def records(root):
    root = Path(root).expanduser().resolve()
    if not root.is_dir():
        raise SafeError('inbox_not_found')
    rows, errors = [], []
    for item in sorted(root.iterdir()):
        if not item.is_dir() or item.name.startswith('.'):
            continue
        if not (item / 'record.json').exists():
            continue
        try:
            rows.append(read(root, item.name))
        except SafeError as error:
            errors.append(dict(id=item.name, error=str(error)))
    return dict(schema_version=1, records=rows, errors=errors)


def clock(ms):
    total = ms // 1000
    return f'{total // 60:02}:{total % 60:02}'


def view(root, output):
    root = Path(root).expanduser().resolve()
    raw_output = Path(output).expanduser().absolute()
    if raw_output.is_symlink():
        raise SafeError('viewer_requires_new_external_directory')
    output = raw_output.resolve()
    # Exports hold sensitive audio. Refuse existing dirs/symlinks, inbox or repo output.
    repo = Path(__file__).resolve().parents[1]
    if (output.exists() or output.is_symlink() or output == root
            or root in output.parents or output == repo or repo in output.parents):
        raise SafeError('viewer_requires_new_external_directory')
    data = records(root)
    output.mkdir(parents=True, mode=0o700)
    import os
    os.chmod(output, 0o700)
    sections = []
    escape = html.escape
    for record in data['records']:
        item_id = record['id']
        audio = ''
        if record['original']['path'] is not None:
            source = root / item_id / 'original.m4a'
            if source.is_symlink() or not source.is_file() or source.stat().st_size > MAX_AUDIO:
                raise SafeError('original_not_found')
            if hashlib.sha256(source.read_bytes()).hexdigest() != record['original']['sha256']:
                raise SafeError('original_checksum_mismatch')
            target = output / (item_id + '.m4a')
            shutil.copyfile(source, target)
            os.chmod(target, 0o600)
            audio = '<audio controls preload="metadata" aria-label="Audio original" src="' + escape(target.name, quote=True) + '"></audio>'
        else:
            audio = '<p class="note">Ejemplo ficticio · sin audio original. No es un resultado de ASR.</p>'
        parts = ''.join('<li><span class="time">' + clock(x['start_ms']) + '–' + clock(x['end_ms']) + '</span><p>' + escape(x['text']) + '</p></li>' for x in record['transcript']['segments'])
        if not parts:
            parts = '<li><p>No se detectó voz en la salida del modelo. Revisá el original: no es una garantía de silencio.</p></li>'
        sections.append('<article><h2>' + escape(item_id) + '</h2>' + audio + '<ol>' + parts + '</ol></article>')
    if not sections:
        sections = ['<p class="empty">Todavía no hay transcripciones. Ejecutá el worker con tu configuración y volvé a generar esta vista.</p>']
    if data['errors']:
        sections.append('<p class="error">Hay ' + str(len(data['errors'])) + ' registros inválidos que no se mostraron. Usá capture list para revisarlos.</p>')
    template = (repo / 'viewer/index.html').read_text()
    page = Template(template).substitute(records='\n'.join(sections), count=str(len(data['records'])))
    (output / 'index.html').write_text(page)
    os.chmod(output / 'index.html', 0o600)
    return dict(output=str(output / 'index.html'), records=len(data['records']), errors=data['errors'])
