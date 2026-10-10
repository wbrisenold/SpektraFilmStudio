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
    sheet=src('StudioRedlampExportDialog.swift')
    delivery=src('StudioExportPreview.swift')
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
    check('StudioRedlampExportDialog(model: model)' in ui and
          'studio.export.shared-modal' in sheet and 'studio.export.preview' in sheet,
          'shared modal must use Redlamp grouped native export component')
    check('StudioExportPreview(model: model, image: currentPhoto)' in sheet and
          'StudioExportPhotoPicker' in sheet and 'choosePhotos = true' in sheet,
          'large actual preview or photo choice inaccessible')
    check('.formStyle(.grouped)' in sheet and 'Section("Location")' in sheet and
          'Section("File")' in sheet and 'Section("Size")' in sheet and
          'Section("Metadata")' in sheet,
          'Redlamp form sections missing from popup')
    check('stroke(Color.yellow' not in delivery and
          'settings.resizeWidth)x' not in delivery and 'settings.dontEnlarge)|' not in delivery,
          'fit guide distortion or redundant spectral render on output resize')
    check('StudioExportSectionLayout' in ui and 'destinationControls' in ui and
          'fileControls' in ui and 'sizeControls' in ui and 'metadataControls' in ui,
          'Redlamp modular export sections regressed')
    check('model.exportSelected()' in sheet and 'model.stopExport()' in sheet and
          'model.resumeExport()' in sheet and 'model.retryFailedExports()' in sheet,
          'export job controller replaced or broken')
    check('model.focusPhoto(currentPhoto.id, destination: .edit)' in sheet and
          'onClose()' in sheet,
          'Edit from popup should close popup and preserve navigation')
    check('case "33": return 33' in lut and 'case "65": return 65' in lut and
          'default: return nil' in lut and 'if !usedSpectralLUT' in preview,
          'experimental LUT/native accuracy guard missing')
    check('struct StudioSliderTrack' in controls and 'thumbX - thumbRadius' in controls,
          'original Redlamp slider layout regressed')
    check((S/'StudioFloatingScopes.swift').exists() and
          'StudioFloatingScopes' in src('EditView.swift'),
          'draggable floating scopes removed')
    check('prepareSelectedFilmLUT()' in src('SettingsView.swift') and
          'func lutBlockReason(' in preview and
          'lutIsPreparing' in src('AppModel.swift'),
          'Prepare Selected Film LUT has no immediate activation or diagnostic')
    print('EXPORT MODAL / SPEED REGRESSION GATE: checks PASS (structural only)')

if __name__ == '__main__': main()
