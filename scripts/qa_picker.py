#!/usr/bin/env python3
"""Regression gate for all studio chooser routes and build provenance."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
sources = root / 'Sources/SpektraFilmFast'
for path in sources.glob('*.swift'):
    text = path.read_text()
    assert not re.search(r'\bNS(?:Open|Save)Panel\s*\(', text), f'{path.name}: remote panel service regression'
    assert '.fileImporter(' not in text, f'{path.name}: competing SwiftUI importer'
for name in ['showingProjectOpenPicker', 'showingImagesImportPicker', 'showingFolderImportPicker', 'showingSourcePicker', 'showingSetupFilePicker']:
    assert not any(name in p.read_text() for p in sources.glob('*.swift')), name
build = (root / 'scripts/build_app.sh').read_text()
assert '--show-bin-path' in build and 'source_binary=${BIN}' in build
assert 'source_commit=${SOURCE_COMMIT}' in build and '<key>SpektraSourceCommit</key>' in build
assert not re.search(r'BIN=.*find ', build)
view = (sources / 'ContentView.swift').read_text()
assert 'sourceCommit.hasSuffix("-dirty")' in view
browser = (sources / 'StudioFileBrowser.swift').read_text()
assert 'Task.detached' in browser and 'self.generation == token' in browser
assert 'This location is not responding' in browser
print('PICKER SOURCE QA PASS')
