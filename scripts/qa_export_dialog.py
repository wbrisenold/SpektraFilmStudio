#!/usr/bin/env python3
"""Static regression contracts for the unified Export sheet.

This deliberately supplements rather than replaces QA 10-pass and an Intel build.
"""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
S = ROOT/'Sources/SpektraFilmFast'

def src(name): return (S/name).read_text()
def check(condition, why):
    if not condition: raise AssertionError('EXPORT REGRESSION: '+why)

def main():
    shell=src('ContentView.swift')
    menus=src('SpektraFilmFastApp.swift')
    ui=src('ExportView.swift')
    lut=src('StudioSpectralLUT.swift')
    preview=src('GPULiveFramePipeline.swift')
    controls=src('StudioUI.swift')
    check('StudioExportEvents.open' in shell and 'studio.export.dialog' in shell,
          'single shared dialog not hosted at root')
    check('ForEach(WorkspacePage.allCases.filter { $0 != .export })' in shell,
          'redundant Export page returned to global nav')
    check('case .export: StudioPalette.canvas' in shell,
          'heavyweight legacy export page must not mount during redirect')
    check('if newPage == .export' in shell and 'openExportDialog()' in shell,
          'legacy page/Omni calls can bypass the shared dialog')
    check('model.setAllExportSelection' not in shell and 'model.toggleExportSelection' not in shell,
          'merely opening the popup must never wipe the user export selection')
    check('ExportWorkspaceView(model: model, isDialog: true)' in shell,
          'dialog host uses a divergent view')
    check('NotificationCenter.default.post(name: StudioExportEvents.open' in menus,
          'File menu must open same modal')
    check('studio.export.shared-modal' in ui and 'studio.export.preview' in ui and
          'StudioExportPreview(model: model, image: image)' in ui,
          'export preview absent or detached from settings')
    check('sourceBrowser' in ui and '.popover(isPresented: $dialogPhotosOpen' in ui,
          'Photos selection no longer accessible')
    check('StudioExportSectionLayout' in ui and 'destinationControls' in ui and
          'fileControls' in ui and 'sizeControls' in ui and 'metadataControls' in ui,
          'Redlamp modular export sections regressed')
    check('model.exportSelected()' in ui and 'model.stopExport()' in ui and
          'model.resumeExport()' in ui and 'model.retryFailedExports()' in ui,
          'export job controller replaced or broken')
    check('model.focusPhoto(image.id, destination: .edit)' in ui and
          'if isDialog { onClose?() }' in ui,
          'Edit from popup should close popup and preserve navigation')
    check('case "33": return 33' in lut and 'case "65": return 65' in lut and
          'default: return nil' in lut and 'if !usedSpectralLUT' in preview,
          'experimental LUT/native accuracy guard missing')
    check('struct StudioSliderTrack' in controls and 'thumbX - thumbRadius' in controls,
          'original Redlamp slider layout regressed')
    check((S/'StudioFloatingScopes.swift').exists() and
          'StudioFloatingScopes' in src('EditView.swift'),
          'draggable floating scopes removed')
    print('EXPORT MODAL / SPEED REGRESSION GATE: 14 checks PASS (structural only)')

if __name__ == '__main__': main()
