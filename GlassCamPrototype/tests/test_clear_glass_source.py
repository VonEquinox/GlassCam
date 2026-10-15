"""Clear-glass camera source contracts, NOT Swift compilation or visual QA.

Together with the independent model in test_camera_geometry.py these checks
protect intended layout and integration boundaries. They do not execute SwiftUI,
prove native Liquid Glass appearance, test camera hardware, or certify hit areas.
Apple SDK/device verification remains required.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
FRAMING = (ROOT / 'ios/GlassCam/CameraFraming.swift').read_text()
CONTENT = (ROOT / 'ios/GlassCam/ContentView.swift').read_text()


def section(source, start, end):
    """Source-order contract helper, not a Swift parser."""
    return source.split(start, 1)[1].split(end, 1)[0]


class ClearGlassSourceContracts(unittest.TestCase):
    def test_full_window_geometry_never_reserves_space_for_controls(self):
        self.assertIn('CameraFraming(size: proxy.size,', VIEW)
        self.assertIn('.ignoresSafeArea()', VIEW)
        self.assertIn('let photoWidth = min(width, height * outputAspect)', FRAMING)
        self.assertIn('let photoHeight = photoWidth / outputAspect', FRAMING)
        self.assertIn('width: photoWidth, height: photoHeight', FRAMING)
        for forbidden in ('controlBand', 'available.width', 'available.height',
                          'safeAreaInsets', 'insetBy(', 'UIScreen.main.bounds'):
            self.assertNotIn(forbidden, FRAMING)
        self.assertNotIn('controlBand:', VIEW)
        self.assertIn('usesVerticalControls = photo.minX > photo.minY', FRAMING)

    def test_perimeter_is_exact_four_way_window_minus_photo_partition(self):
        panes = section(FRAMING, 'perimeter = [', '].filter')
        for token in ('width: width, height: photo.minY',
                      'y: photo.maxY, width: width, height: height - photo.maxY',
                      'width: photo.minX, height: photo.height',
                      'x: photo.maxX, y: photo.minY, width: width - photo.maxX, height: photo.height'):
            self.assertIn(token, panes)
        self.assertIn('].filter { $0.width > 0 && $0.height > 0 }', FRAMING)
        self.assertEqual(panes.count('CGRect('), 4)

    def test_clear_glass_uses_native_api_without_frosted_or_synthetic_fallback(self):
        self.assertIn('content.glassEffect(.clear, in: Rectangle())', VIEW)
        self.assertEqual(VIEW.count('.glassEffect('), 1)
        for forbidden in ('.glassEffect(.regular', '.buttonStyle(.glass)',
                          '.ultraThinMaterial', '.thinMaterial', '.regularMaterial',
                          '.thickMaterial', '.ultraThickMaterial', 'UIBlurEffect',
                          'UIVisualEffectView', '.blur(', '.layerEffect(',
                          '.distortionEffect(', 'ShaderLibrary',
                          'UIGraphicsImageRenderer', 'drawHierarchy', '.snapshot(',
                          '.resizeAspectFill', 'scaleEffect(x: -1'):
            self.assertNotIn(forbidden, VIEW)

    def test_native_glass_modifier_is_only_applied_to_perimeter_panes(self):
        panes = section(VIEW, 'ForEach(Array(framing.perimeter.enumerated())',
                        'if let layer = camera.centerPreviewLayer')
        self.assertIn('.modifier(CameraPaneGlass())', panes)
        self.assertIn('.frame(width: pane.width, height: pane.height)', panes)
        self.assertIn('.clipped()', panes)
        self.assertIn('.position(x: pane.midX, y: pane.midY)', panes)
        self.assertIn('.allowsHitTesting(false)', panes)
        self.assertEqual(VIEW.count('.modifier(CameraPaneGlass())'), 1)
        self.assertLess(VIEW.index('ForEach(Array(framing.perimeter.enumerated())'),
                        VIEW.index('if let layer = camera.centerPreviewLayer'))

    def test_photo_and_live_proxy_remain_plain_aspect_fit_at_same_photo_rect(self):
        center = section(VIEW, 'if let layer = camera.centerPreviewLayer',
                         'if let source = camera.centerLiveSource')
        proxy = section(VIEW, 'if let source = camera.centerLiveSource',
                        'if !camera.isCapturing && (!camera.isReady')
        self.assertIn('CameraPreview(layer: layer, gravity: .resizeAspect)', center)
        self.assertIn('.background(.black)', center)
        for source in (center, proxy):
            self.assertIn('.frame(width: framing.photo.width, height: framing.photo.height)', source)
            self.assertIn('.position(x: framing.photo.midX, y: framing.photo.midY)', source)
            self.assertIn('.clipped()', source)
            for forbidden in ('glassEffect', 'CameraPaneGlass', 'RoundedRectangle',
                              'cornerRadius(', '.scaledToFill()', '.scaleEffect('):
                self.assertNotIn(forbidden, source)
        self.assertIn('enabled: experimentalLiveColor && scenePhase == .active && !camera.isPreviewFrozen', proxy)

    def test_physical_periphery_retains_fov_mapping_and_coverage_gate(self):
        periphery = section(VIEW, 'if let layer = camera.peripheralPreviewLayer',
                            'ForEach(Array(framing.perimeter.enumerated())')
        self.assertIn('let extent = framing.peripheral', periphery)
        self.assertIn('framing.hasPeripheralCoverage', periphery)
        self.assertIn('CameraPreview(layer: layer, gravity: .resizeAspect)', periphery)
        self.assertIn('.frame(width: extent.width, height: extent.height)', periphery)
        self.assertIn('.position(x: extent.midX, y: extent.midY)', periphery)
        self.assertIn('tan(Double(widerFOV) * .pi / 360)', FRAMING)
        self.assertIn('tan(Double(centerFOV) * .pi / 360)', FRAMING)
        self.assertIn('if aspect < 1', FRAMING)
        self.assertIn('rect.minX <= 0 && rect.minY <= 0 && rect.maxX >= width && rect.maxY >= height', FRAMING)
        self.assertIn('selectedLens == .ultraWide || framing.hasPeripheralCoverage', VIEW)

    def test_reference_style_has_brand_flash_grid_status_and_photo_only(self):
        controls = section(VIEW, 'private func controls(', 'private var wordmark:')
        portrait = section(controls, 'case .portrait:', 'case .landscape:')
        ordered = ['flashOff', 'wordmark', 'gridButton', 'captureMetadata',
                   'photoMode', 'thumbnailButton', 'shutter(', 'settingsButton']
        cursor = -1
        for token in ordered:
            cursor = portrait.find(token, cursor + 1)
            self.assertGreaterEqual(cursor, 0, token)
        self.assertIn('Text("GLASSCAM")', VIEW)
        wordmark = section(VIEW, 'private var wordmark:', 'private var flashOff:')
        self.assertIn('.tracking(3.5)', wordmark)
        flash = section(VIEW, 'private var flashOff:', 'private var gridButton:')
        self.assertIn('Image(systemName: "bolt.slash")', flash)
        self.assertIn('.accessibilityLabel("Flash off")', flash)
        self.assertNotIn('Button {', flash)
        photo_mode = section(VIEW, 'private var photoMode:', 'private var photoAspectLabel:')
        self.assertIn('"Photo"', photo_mode)
        self.assertIn('experimentalLiveColor', photo_mode)
        self.assertIn('liveProxyStatus.isShowingEffect', photo_mode)
        self.assertIn('camera.isReady && !camera.isPreviewFrozen', photo_mode)
        self.assertNotRegex(VIEW, r'Text\("(?:Video|Portrait|视频|人像)"\)')
        self.assertIn('camera.geometry?.sensorPhotoDimensions', VIEW)
        self.assertIn('case .main: return "1×"', VIEW)
        self.assertIn('case .ultraWide: return "Ultra"', VIEW)
        self.assertIn('case .telephoto: return "Tele"', VIEW)
        self.assertIn('Text("RAW")', VIEW)

    def test_composition_grid_is_real_toggle_scoped_to_photograph(self):
        self.assertIn('@State private var gridVisible = true', VIEW)
        button = section(VIEW, 'private var gridButton:', 'private var captureMetadata:')
        self.assertIn('gridVisible.toggle()', button)
        self.assertIn('"Hide composition grid" : "Show composition grid"', button)
        placement = section(VIEW, 'PhotoFrameGuide(gridVisible: gridVisible)',
                            'if !camera.isCapturing && (!camera.isReady')
        self.assertIn('.frame(width: framing.photo.width, height: framing.photo.height)', placement)
        self.assertIn('.position(x: framing.photo.midX, y: framing.photo.midY)', placement)
        self.assertIn('.allowsHitTesting(false)', placement)
        guide = section(VIEW, 'private struct PhotoFrameGuide:', 'private struct CameraPaneGlass:')
        self.assertIn('if gridVisible {', guide)
        self.assertIn('CGFloat(1) / 3, CGFloat(2) / 3', guide)
        self.assertNotIn('glassEffect', guide)
        self.assertNotIn('CameraPreview', guide)

    def test_thumbnail_is_actual_image_with_honest_empty_state_and_editor_action(self):
        self.assertIn('let thumbnail: PreviewRaster?', VIEW)
        thumbnail = section(VIEW, 'private var thumbnailButton:', 'private var settingsButton:')
        self.assertIn('Button(action: closeCamera)', thumbnail)
        self.assertIn('if let thumbnail {', thumbnail)
        self.assertIn('PrecisionPreview(source: thumbnail)', thumbnail)
        self.assertIn('Image(systemName: "photo.on.rectangle")', thumbnail)
        self.assertIn('"Open editor and import a photo"', thumbnail)
        self.assertIn('"Open photo in editor"', thumbnail)
        self.assertNotIn('Image("', thumbnail)
        self.assertNotIn('UIImage(', thumbnail)
        self.assertNotIn('.disabled(', thumbnail)

    def test_compact_layout_uses_separate_plain_panel_and_accessible_reopen(self):
        layout = section(VIEW, 'private struct CameraChromeLayout', 'private struct PhotoFrameGuide')
        self.assertIn('rect.intersection(safe)', layout)
        self.assertIn('intersection.insetBy(dx: 8, dy: 4)', layout)
        self.assertIn('needsAccessiblePanel', layout)
        self.assertIn('style = .separate', layout)
        self.assertNotRegex(layout, r'framing\.photo\s*=')
        self.assertNotIn('CameraFraming(size:', layout)
        for threshold in ('first.width >= 44, second.width >= 56',
                          'first.height >= 44, second.height >= 56',
                          'min(first.height, second.height) >= 212',
                          'min(first.width, second.width) >= 312'):
            self.assertIn(threshold, layout)
        self.assertIn('.sheet(item: $activePanel)', VIEW)
        self.assertIn('.presentationBackground(Color.black)', VIEW)
        panel = section(VIEW, 'private func cameraPanel(', 'private var orientedPeripheralAspectRatio:')
        self.assertIn('.scrollContentBackground(.hidden)', panel)
        self.assertIn('.background(Color.black)', panel)
        self.assertIn('tap it to reopen these controls.', panel)
        self.assertIn('Button(panel == .compact ? "Viewfinder" : "Done") { activePanel = nil }', panel)
        gesture = section(VIEW, 'if chrome.style == .separate &&', 'controls(framing: framing, chrome: chrome)')
        self.assertIn('.onTapGesture { activePanel = .compact }', gesture)
        self.assertIn('.accessibilityAction { activePanel = .compact }', gesture)
        self.assertIn('.accessibilityLabel("Viewfinder. Open camera controls")', gesture)
        self.assertNotIn('captureProRAW', gesture)

    def test_compact_error_card_keeps_retry_and_controls_accessible(self):
        error = section(VIEW, 'if !camera.isCapturing && (!camera.isReady',
                        'if chrome.style == .separate &&')
        self.assertIn('Button("Retry camera") { restartCamera() }', error)
        self.assertIn('if chrome.style == .separate {', error)
        self.assertIn('Button("Open camera controls") { activePanel = .compact }', error)
        gesture = section(VIEW, 'if chrome.style == .separate &&',
                          'controls(framing: framing, chrome: chrome)')
        self.assertIn('(camera.isCapturing || (camera.isReady && coverageAvailable(framing)))', gesture)
        self.assertIn('.onTapGesture { activePanel = .compact }', gesture)
        self.assertNotIn('restartCamera()', gesture)

    def test_compact_modal_does_not_reopen_on_dismissal_or_during_capture(self):
        offer = section(VIEW, 'private func offerCompactPanel(', 'private func closeCamera()')
        self.assertIn('guard camera.geometry != nil else { return }', offer)
        self.assertIn('guard style == .separate else { compactPanelOffered = false; return }', offer)
        self.assertIn('!compactPanelOffered, !isClosing, !camera.isCapturing', offer)
        self.assertIn('!camera.isPreviewFrozen else { return }', offer)
        self.assertLess(offer.index('compactPanelOffered = true'), offer.index('activePanel = .compact'))
        self.assertIn('.onChange(of: camera.geometry?.photoAspectRatio)', VIEW)
        self.assertIn('.onChange(of: camera.isReady)', VIEW)
        self.assertIn('.onChange(of: camera.isPreviewFrozen)', VIEW)
        shutter = section(VIEW, 'private func shutter(', 'private enum CameraPanel:')
        self.assertLess(shutter.index('activePanel = nil'), shutter.index('camera.captureProRAW'))

    def test_settings_keep_effect_output_preview_and_editor_access(self):
        settings = section(VIEW, 'private func cameraPanel(', 'private var orientedPeripheralAspectRatio:')
        for token in ('Picker("Color engine", selection: $colorMode)',
                      'FFCSReferenceControls(settings: $ffcs, simulationIndex: $simulationIndex)',
                      'Slider(value: $exposureEV, in: -2...2, step: 0.05)',
                      'Slider(value: $illuminantKelvin, in: 2000...10000, step: 50)',
                      'camera.supportedOutputOptions', 'selection: outputSelection',
                      'selection: $settings.centerPreviewLongEdge',
                      'selection: $settings.peripheralPreviewLongEdge',
                      'Toggle("Experimental live color (approx.)", isOn: $experimentalLiveColor)',
                      'Compare, save and share in the editor.',
                      'Button("Close camera", action: closeCamera)'):
            self.assertIn(token, settings)
        for token in ('@Binding var exposureEV: Double', '@Binding var illuminantKelvin: Double'):
            self.assertIn(token, VIEW)
        self.assertIn('@State private var experimentalLiveColor = false', VIEW)
        self.assertIn('liveRecipe.unsupportedReason', settings)
        self.assertIn('Apple GPU validation pending', settings)
        self.assertIn('not measured camera WB', settings)

    def test_chrome_legibility_shadow_is_clipped_to_spare_region(self):
        region = section(VIEW, 'private struct CameraChromeRegion:', 'private struct PhotoFrameGuide:')
        tokens = ['.frame(width: rect.width, height: rect.height)',
                  '.shadow(', '.clipped()', '.position(x: rect.midX, y: rect.midY)']
        cursor = -1
        for token in tokens:
            cursor = region.find(token, cursor + 1)
            self.assertGreaterEqual(cursor, 0, token)
        controls = section(VIEW, 'private func controls(', 'private var wordmark:')
        self.assertEqual(controls.count('.modifier(CameraChromeRegion(rect: chrome.first))'), 4)
        self.assertEqual(controls.count('.modifier(CameraChromeRegion(rect: chrome.second))'), 4)
        self.assertNotIn('.glassEffect(', region)
        self.assertNotIn('.background(', region)
        lens = section(VIEW, 'private var lensMenu:', 'private var thumbnailButton:')
        self.assertIn('.frame(minWidth: 44, minHeight: 44)', lens)

    def test_old_sdk_and_os_fallback_is_plain_and_disclosed(self):
        glass = section(VIEW, 'private struct CameraPaneGlass:', 'private struct CameraPreview:')
        self.assertIn('#if compiler(>=6.2)', glass)
        self.assertIn('if #available(iOS 26.0, *)', glass)
        self.assertIn('#else\n        content\n        #endif', glass)
        self.assertNotIn('.background(', glass)
        self.assertIn('Native clear glass requires iOS 26.', VIEW)
        self.assertIn('Native clear glass requires the iOS 26 SDK.', VIEW)

    def test_editor_passes_actual_photo_and_mutable_recipe_to_camera(self):
        camera = section(CONTENT, 'CameraView(', '.sheet(item: $model.fileSave)')
        self.assertIn('colorMode: $model.colorMode', camera)
        self.assertIn('simulationIndex: $model.simulationIndex', camera)
        self.assertIn('exposureEV: $model.exposure', camera)
        self.assertIn('illuminantKelvin: $model.kelvin', camera)
        self.assertIn('thumbnail: model.processed?.image ?? model.imported?.original', camera)
        self.assertIn('model.selectCapture(data, settings: settings, capturedRecipe: capturedRecipe, ticket: sessionTicket)', camera)
        self.assertIn('if cameraSession?.id == sessionTicket { cameraSession = nil }', camera)
        self.assertIn('Task { await model.renderIfNeeded() }', CONTENT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
