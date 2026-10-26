"""Opaque camera chrome source contracts, NOT Swift compilation or visual QA.

Together with the independent model in test_camera_geometry.py these checks
protect intended layout and integration boundaries. They do not execute SwiftUI,
prove rendered appearance, test camera hardware, or certify hit areas.
Apple SDK/device verification remains required.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
FRAMING = (ROOT / 'ios/GlassCam/CameraFraming.swift').read_text()
CONTENT = (ROOT / 'ios/GlassCam/ContentView.swift').read_text()
DESIGN = (ROOT / 'ios/GlassCam/CameraDesign.swift').read_text()
SHADER = (ROOT / 'ios/GlassCam/PeripheralGlassShader.swift').read_text()
GLASS = (ROOT / 'ios/GlassCam/PeripheralGlassView.swift').read_text()
POLICY = (ROOT / 'ios/GlassCam/PeripheralGlassPolicy.swift').read_text()
CONTROLLER = (ROOT / 'ios/GlassCam/CameraController.swift').read_text()
LIVE = (ROOT / 'ios/GlassCam/LiveColorProxy.swift').read_text()


def section(source, start, end):
    """Source-order contract helper, not a Swift parser."""
    return source.split(start, 1)[1].split(end, 1)[0]


class CameraChromeSourceContracts(unittest.TestCase):
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

    def test_liquid_glass_is_clear_and_owned_by_the_perimeter_panes_only(self):
        # System Liquid Glass is the periphery material. It lives in one view
        # whose panes are exactly CameraFraming.perimeter (window minus photo).
        for source in (VIEW, CONTENT, DESIGN):
            for token in ('.glassEffect(', 'UIGlassEffect', 'CABackdropLayer', 'UIVisualEffectView'):
                self.assertNotIn(token, source)
        liquid = section(GLASS, 'struct PeripheralLiquidGlass: View', '\n}\n')
        self.assertIn('GlassEffectContainer', liquid)
        self.assertIn('ForEach(Array(framing.perimeter.enumerated())', liquid)
        self.assertIn('.glassEffect(.clear, in: Rectangle())', liquid)
        self.assertIn('.frame(width: pane.width, height: pane.height)', liquid)
        self.assertIn('.position(x: pane.midX, y: pane.midY)', liquid)
        self.assertIn('.allowsHitTesting(false)', liquid)
        self.assertEqual(GLASS.count('.glassEffect('), 1)
        for forbidden in ('.regular', 'framing.photo', 'framing.window.width * ', 'cornerRadius'):
            self.assertNotIn(forbidden, liquid)
        # Raw fallback lies below the atomic paired drawable. Native glass is
        # masked to the periphery; controls remain above all preview surfaces.
        order = ['CameraPreview(layer: layer', 'PeripheralGlassView(source:', 'PeripheralLiquidGlass(framing: framing)',
                 'LiveColorProxy(source: source',
                 'PhotoFrameBoundary(rect: framing.photo)', 'PhotoFrameGuide(gridVisible:',
                 'controls(framing: framing, chrome: chrome)']
        self.assertEqual([VIEW.index(t) for t in order], sorted(VIEW.index(t) for t in order))
        for forbidden in ('.glassEffect(.regular', '.buttonStyle(.glass)',
                          '.ultraThinMaterial', '.thinMaterial', '.regularMaterial',
                          '.thickMaterial', '.ultraThickMaterial', 'UIBlurEffect',
                          'UIVisualEffectView', '.blur(', '.layerEffect(',
                          '.distortionEffect(', 'ShaderLibrary',
                          'UIGraphicsImageRenderer', 'drawHierarchy', '.snapshot(',
                          '.resizeAspectFill', 'scaleEffect(x: -1'):
            self.assertNotIn(forbidden, VIEW)

    def test_paired_renderer_keeps_glass_outside_the_unshaded_center(self):
        outer = section(VIEW, 'PeripheralGlassView(source:', 'PeripheralLiquidGlass(framing: framing)')
        self.assertIn('framing: framing', outer)
        self.assertIn('.allowsHitTesting(false)', outer)
        self.assertIn('!settingsPresented && reviewedCapture == nil', outer)
        self.assertIn('!camera.isPreviewFrozen', outer)
        self.assertLess(VIEW.index('if let layer = camera.centerPreviewLayer'), VIEW.index('PeripheralGlassView(source:'))
        self.assertIn('pairedPreviewFragment', SHADER)
        self.assertIn('center.sample(s,(uv-u.photo.xy)/u.photo.zw)', SHADER)
        self.assertIn('let bundle = uploading ?? textures.completed', GLASS)
        self.assertIn('includeCenter:true', GLASS)
        self.assertIn('if (all(uv >= u.photo.xy) && all(uv < end)) discard_fragment();', SHADER)
        self.assertLess(SHADER.index('discard_fragment()'), SHADER.index('camera.sample('))
        self.assertIn('if (u.blackOpacity >= 0.9999) return float4(0,0,0,1);', SHADER)
        # Liquid Glass supplies the material: one unblurred tap, matched brightness.
        self.assertEqual(SHADER.count('camera.sample('), 1)
        for forbidden in ('exp(-distance', 'rim', '0.77', 'for (int'):
            self.assertNotIn(forbidden, SHADER)
        self.assertIn('PeripheralProjection.margin(matrix,window: window,width: outerWidth,height: outerHeight)', GLASS)
        self.assertIn('live.resourceValid(bundle,revision:revision,at:now)', GLASS)
        self.assertIn('live.update(pair:pair,analysis:alignment', GLASS)
        self.assertIn('.mask {', GLASS)

    def test_darkness_follows_distortion_continuously_with_latched_black(self):
        for token in ('static let fadeStart = 0.05', 'static let darkeningThreshold = 0.10',
                      'static let recoveryThreshold = 0.08', 'static let darkeningDuration = 0.30',
                      'static let recoveryDuration = 0.40', 'static let recoveryStability = 0.40',
                      'static func darkness(forError error: Double)'):
            self.assertIn(token, POLICY)
        self.assertIn('var latched: Bool { recoveryLatched || proofExpired }', POLICY)

    def test_viewfinder_prefers_60_hz_and_falls_back_keeping_the_periphery(self):
        self.assertIn('for fps: Int32 in [60, 30, 15] {', CONTROLLER)
        self.assertNotIn('for fps: Int32 in [30, 15]', CONTROLLER)
        single = section(CONTROLLER, 'private func applyPreviewFrameRate(', 'private func photoCapability(')
        self.assertIn('let fps: Int32 = 60', single)
        self.assertIn('videoSupportedFrameRateRanges', single)
        self.assertNotIn('activeFormat =', single)
        self.assertIn('if includePreview { try applyPreviewFrameRate(center) }', CONTROLLER)
        self.assertIn('view.preferredFramesPerSecond = 60', GLASS)
        self.assertIn('link.preferredFramesPerSecond = 60', LIVE)

    def test_photo_and_live_proxy_remain_plain_aspect_fit_at_same_photo_rect(self):
        center = section(VIEW, 'if let layer = camera.centerPreviewLayer',
                         'if let source = camera.centerLiveSource')
        proxy = section(VIEW, 'if let source = camera.centerLiveSource',
                        'if !camera.isCapturing && !camera.isReady')
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


    def test_viewfinder_exposes_real_photo_quick_controls_outside_center(self):
        controls = section(VIEW, 'private func controls(', 'private var wordmark:')
        portrait = section(controls, 'case .portrait:', 'case .landscape:')
        ordered = ['resolutionButton', 'wordmark', 'gridButton', 'captureMetadata',
                   'zoomButtons', 'lensIndicator', 'thumbnailButton', 'shutter(', 'settingsButton']
        cursor = -1
        for token in ordered:
            cursor = portrait.find(token, cursor + 1)
            self.assertGreaterEqual(cursor, 0, token)
        self.assertIn('Text("GLASSCAM")', VIEW)
        wordmark = section(VIEW, 'private var wordmark:', 'private var gridButton:')
        self.assertIn('.tracking(3.5)', wordmark)
        metadata = section(VIEW, 'private var captureMetadata:', 'private var styleButton:')
        self.assertIn('styleButton', metadata)
        self.assertIn('statusButton', metadata)
        self.assertNotIn('workflowStatus', VIEW[:VIEW.index('controls(framing: framing, chrome: chrome)')])
        summary = section(VIEW, 'private var summaryStatus:', 'private var photoAspectLabel:')
        self.assertIn('liveProxyStatus.isShowingEffect', summary)
        self.assertIn('Approx. preview · HDR', summary)
        self.assertNotRegex(VIEW, r'Text\("(?:Video|Portrait|视频|人像)"\)')
        self.assertIn('camera.geometry?.sensorPhotoDimensions', VIEW)
        self.assertIn('CameraZoomRange.label(camera.requestedZoom)', VIEW)
        self.assertIn('Focal length controls', VIEW)
        self.assertIn('Text("RAW")', VIEW)

    def test_composition_grid_is_real_toggle_scoped_to_photograph(self):
        self.assertIn('private var gridVisible: Bool { settings.gridVisible }', VIEW)
        button = section(VIEW, 'private var gridButton:', 'private var captureMetadata:')
        self.assertIn('gridVisible.toggle()', button)
        self.assertIn('"Hide composition grid" : "Show composition grid"', button)
        placement = section(VIEW, 'PhotoFrameGuide(gridVisible: gridVisible)',
                            'if !camera.isCapturing && !camera.isReady')
        self.assertIn('.frame(width: framing.photo.width, height: framing.photo.height)', placement)
        self.assertIn('.position(x: framing.photo.midX, y: framing.photo.midY)', placement)
        self.assertIn('.allowsHitTesting(false)', placement)
        guide = section(VIEW, 'private struct PhotoFrameGuide:', 'private struct CameraPreview:')
        self.assertIn('if gridVisible {', guide)
        self.assertIn('CGFloat(1) / 3, CGFloat(2) / 3', guide)
        self.assertNotIn('glassEffect', guide)
        self.assertNotIn('CameraPreview', guide)

    def test_thumbnail_is_actual_image_with_honest_empty_state_and_editor_action(self):
        self.assertIn('workflow.latest?.preview', VIEW)
        thumbnail = section(VIEW, 'private var thumbnailButton:', 'private var settingsButton:')
        self.assertIn('destination = .photo(capture)', thumbnail)
        self.assertIn('PrecisionPreview(source: thumbnail)', thumbnail)
        self.assertIn('Image(systemName: "photo.on.rectangle")', thumbnail)
        self.assertIn('.disabled(workflow.latest == nil || workflow.isWorking)', thumbnail)
        self.assertIn('View latest saved photo', thumbnail)
        self.assertNotIn('editor', thumbnail)

    def test_compact_layout_uses_separate_plain_panel_and_accessible_reopen(self):
        layout = section(VIEW, 'private struct CameraChromeLayout', 'private struct PhotoFrameGuide')
        self.assertIn('rect.intersection(safe)', layout)
        self.assertIn('intersection.insetBy(dx: 8, dy: 4)', layout)
        self.assertIn('needsAccessiblePanel', layout)
        self.assertIn('style = .separate', layout)
        self.assertNotRegex(layout, r'framing\.photo\s*=')
        self.assertNotIn('CameraFraming(size:', layout)
        for threshold in ('first.width >= 68, second.width >= 64',
                          'first.height >= 44, second.height >= 56',
                          'min(first.height, second.height) >= 264',
                          'min(first.width, second.width) >= 312'):
            self.assertIn(threshold, layout)
        self.assertIn('.sheet(item: $activePanel)', VIEW)
        # Panels use the system Liquid Glass sheet, not an opaque override.
        self.assertNotIn('.presentationBackground(', VIEW)
        panel = section(VIEW, 'private func cameraPanel(', 'private var selectedOutput:')
        self.assertNotIn('CameraSettingsBackground()', panel)
        self.assertIn('backIdentifier: "camera.panel.back"', panel)
        self.assertIn('activePanel = nil', panel)
        gesture = section(VIEW, 'if camera.centerPreviewLayer != nil', 'controls(framing: framing, chrome: chrome)')
        self.assertIn('.onTapGesture { if chrome.style == .separate { activePanel = .compact } }', gesture)
        self.assertIn('.accessibilityAction { if chrome.style == .separate { activePanel = .compact } }', gesture)
        self.assertIn('.accessibilityLabel("Viewfinder. Open camera controls")', gesture)
        self.assertNotIn('captureProRAW', gesture)

    def test_compact_error_card_keeps_retry_and_controls_accessible(self):
        error = section(VIEW, 'if !camera.isCapturing && !camera.isReady',
                        'if camera.centerPreviewLayer != nil')
        self.assertIn('Button("Retry camera") { restartCamera() }', error)
        self.assertIn('if chrome.style == .separate {', error)
        self.assertIn('Button("Open camera controls") { activePanel = .compact }', error)
        gesture = section(VIEW, 'if camera.centerPreviewLayer != nil',
                          'controls(framing: framing, chrome: chrome)')
        self.assertIn('MagnificationGesture()', gesture)
        self.assertIn('.onTapGesture { if chrome.style == .separate { activePanel = .compact } }', gesture)
        self.assertNotIn('restartCamera()', gesture)

    def test_compact_modal_does_not_reopen_on_dismissal_or_during_capture(self):
        offer = section(VIEW, 'private func offerCompactPanel(', 'private func restartCamera()')
        self.assertIn('guard camera.geometry != nil else { return }', offer)
        self.assertIn('guard style == .separate else { compactPanelOffered = false; return }', offer)
        self.assertIn('!compactPanelOffered, !settingsPresented, reviewedCapture == nil, !camera.isCapturing', offer)
        self.assertIn('!camera.isPreviewFrozen else { return }', offer)
        self.assertLess(offer.index('compactPanelOffered = true'), offer.index('activePanel = .compact'))
        self.assertIn('.onChange(of: camera.geometry?.photoAspectRatio)', VIEW)
        self.assertIn('.onChange(of: camera.isReady)', VIEW)
        self.assertIn('.onChange(of: camera.isPreviewFrozen)', VIEW)
        shutter = section(VIEW, 'private func shutter(', 'private enum CameraPanel:')
        self.assertLess(shutter.index('activePanel = nil'), shutter.index('camera.capturePhoto'))

    def test_settings_keep_effect_output_preview_and_editor_access(self):
        settings = section(VIEW, 'private struct CameraSettingsView:', 'private struct CaptureReview:')
        for token in ('Picker("Color engine", selection: $settings.colorMode)',
                      'FFCSReferenceControls(settings: $settings.ffcs, simulationIndex: $settings.simulationIndex)',
                      'Slider(value: $settings.exposure, in: -2...2, step: 0.05)',
                      'HNCSPresetControls(settings: $settings.hncs, showCommon: false)',
                      'selection: outputSelection', 'selection: $settings.centerPreviewLongEdge',
                      'isOn: $settings.experimentalLiveColor', 'smaller framed sources save at 24 MP',
                      'ForEach(settings.captureQuality == .speed ? [12] : [24, 48]',
                      'CameraCard(title: "Photo output"', 'if advanced { advancedCards } else { commonCards }'):
            self.assertIn(token, settings)
        self.assertIn('.fullScreenCover(item: $destination', VIEW)
        self.assertIn('Image(systemName: "gearshape")', VIEW)
        self.assertNotIn('Open editor', VIEW)

    def test_controls_are_clipped_to_the_peripheral_regions(self):
        region = section(VIEW, 'private struct CameraChromeRegion:', 'private struct PhotoFrameGuide:')
        tokens = ['.frame(width: rect.width, height: rect.height)',
                  '.clipped()', '.position(x: rect.midX, y: rect.midY)']
        cursor = -1
        for token in tokens:
            cursor = region.find(token, cursor + 1)
            self.assertGreaterEqual(cursor, 0, token)
        controls = section(VIEW, 'private func controls(', 'private var wordmark:')
        self.assertEqual(controls.count('.modifier(CameraChromeRegion(rect: chrome.first))'), 4)
        self.assertEqual(controls.count('.modifier(CameraChromeRegion(rect: chrome.second))'), 4)
        self.assertNotIn('.glassEffect(', region)
        self.assertNotIn('.background(', region)
        lens = section(VIEW, 'private var lensIndicator:', 'private var thumbnailButton:')
        self.assertIn('.frame(minWidth: 44, minHeight: 44)', lens)


    def test_editor_passes_actual_photo_and_mutable_recipe_to_camera(self):
        self.assertIn('@StateObject private var settings = CameraSettingsStore()', CONTENT)
        self.assertIn('@StateObject private var workflow = CaptureWorkflow(', CONTENT)
        self.assertIn('CameraView(settings: settings, workflow: workflow)', CONTENT)
        self.assertNotIn('EditorModel', CONTENT)
        self.assertNotIn('PhotosPicker', CONTENT)
        review = VIEW.split('private struct CaptureReview:', 1)[1]
        self.assertIn('PrecisionPreview(source: capture.preview)', review)
        self.assertIn('ShareSheet(file: capture.file)', review)
        self.assertIn('MagnificationGesture()', review)
        self.assertNotIn('ImagePipeline.process', review)

if __name__ == '__main__':
    unittest.main(verbosity=2)
