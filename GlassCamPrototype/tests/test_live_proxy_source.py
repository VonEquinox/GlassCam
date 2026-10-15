"""Static live-color integration contracts, NOT Swift/Apple SDK or GPU tests.

These checks protect the opt-in gate, ownership/lifecycle wiring and isolation
from precise photos. Device color, orientation, performance and visual fallback
still require Apple-platform tests from docs/LIVE_COLOR_PROXY_PLAN.md.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROXY = (ROOT / 'ios/GlassCam/LiveColorProxy.swift').read_text()
VIEW = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
CONTROLLER = (ROOT / 'ios/GlassCam/CameraController.swift').read_text()
DELIVERY = (ROOT / 'ios/GlassCam/CameraFrameDelivery.swift').read_text()
CONTENT = (ROOT / 'ios/GlassCam/ContentView.swift').read_text()
PROJECT = (ROOT / 'ios/GlassCam.xcodeproj/project.pbxproj').read_text()


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class LiveProxySourceContracts(unittest.TestCase):
    def test_experiment_is_default_off_and_center_only(self):
        self.assertIn('@State private var experimentalLiveColor = false', VIEW)
        self.assertEqual(VIEW.count('LiveColorProxy(source:'), 1)
        self.assertIn('if let source = camera.centerLiveSource', VIEW)
        self.assertIn('Toggle("Experimental live color (approx.)"', VIEW)
        self.assertIn('enabled: experimentalLiveColor && scenePhase == .active', VIEW)
        self.assertLess(VIEW.index('CameraPreview(layer: layer, gravity: .resizeAspect)'),
                        VIEW.index('LiveColorProxy(source:'))
        self.assertIn('Viewfinder color only', VIEW)
        self.assertIn('Apple GPU validation pending', VIEW)
        self.assertIn('visible color errors possible', VIEW)

    def test_precise_photo_and_export_do_not_depend_on_proxy(self):
        for filename in ('ImagePipeline.swift', 'HNCSEngine.swift', 'FFCSEngine.swift',
                         'SourceImageStore.swift', 'ExportSettings.swift',
                         'HEIFSaveDelivery.swift', 'ShareDelivery.swift'):
            source = (ROOT / 'ios/GlassCam' / filename).read_text()
            self.assertNotIn('LiveColor', source, filename)
            self.assertNotIn('liveSource', source, filename)
        capture = section(CONTROLLER, 'func captureProRAW(', 'deinit')
        self.assertNotIn('liveSource', capture)
        self.assertNotIn('LiveColor', capture)
        shutter = section(VIEW, 'private func shutter(', 'private enum CameraPanel')
        self.assertNotIn('experimentalLiveColor', shutter)
        self.assertNotIn('liveProxyStatus', shutter)
        self.assertIn('camera.captureProRAW', shutter)

    def test_only_measured_recipe_allowlist_is_enabled(self):
        gate = section(PROXY, 'var unsupportedReason:', '/// Retains the original tagged buffer')
        self.assertIn('guard exposureEV == 0', gate)
        self.assertIn('![5500.0, 6500.0].contains(illuminantKelvin)', gate)
        self.assertIn('(0..<Int(ffcs_simulation_count())).contains(simulationIndex)', gate)
        self.assertIn('[0, 8].contains(simulationIndex)', gate)
        self.assertIn('ffcs.cameraFamily == .xh2s, !ffcs.applyReferenceAdjustments', gate)
        self.assertIn('ffcs.sharpenRadius == 1.0', gate)
        self.assertIn('FFCSEngine.isSimulationAvailable', gate)
        self.assertIn('static let dimension = 65', PROXY)
        self.assertIn('exposureEV: $model.exposure, illuminantKelvin: $model.kelvin', CONTENT)
        self.assertIn('simulationIndex: colorMode == .ffcs ? simulationIndex : 0', VIEW)

    def test_cube_is_baked_from_actual_pointwise_cores(self):
        bake = section(PROXY, 'private func bake(', 'private enum LiveSourceValidation')
        for token in ('hncs_create(recipe.exposureEV, recipe.illuminantKelvin)',
                      'hncs_process_linear_rgba(', 'ffcs_create_family_config(',
                      'ffcs_process_linear_rgb_color_only(', 'hncs_destroy(hncs)',
                      'ffcs_destroy(ffcs)', 'slabPixels * 4', 'source.count',
                      'rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) })',
                      'allSatisfy({ rgba[$0] == 1 })', 'Data($0)'):
            self.assertIn(token, bake)
        self.assertNotIn('ffcs_process_linear_rgb(', bake)
        self.assertNotIn('hncs_process_srgb(', bake)
        self.assertIn('q <= 0.04045 ? q / 12.92', bake)
        self.assertIn('pow((q + 0.055) / 1.055, 2.4)', bake)
        self.assertLess(bake.index('for blue in'), bake.index('for green in'))
        self.assertLess(bake.index('for green in'), bake.index('for red in'))
        self.assertIn('(green * n + red) * 3', bake)
        self.assertIn('advanced(by: blue * slabPixels * 4)', bake)

    def test_bakes_are_bounded_cancelable_and_cached(self):
        store = section(PROXY, 'private final class LiveColorCubeStore', 'private enum LiveSourceValidation')
        for token in ('private var pending: Request?', 'private var running = false',
                      'private let cacheLimit = 2', 'pending = Request(',
                      'let start = !running', 'if start { running = true }',
                      'revision &+= 1; pending = nil', 'guard isCurrent(ticket)',
                      'guard current else { continue }', 'self.isCurrent(request.revision)',
                      'cache.firstIndex { $0.recipe == request.recipe }', 'qos: .utility'):
            self.assertIn(token, store)
        draw = section(PROXY, 'func draw(in view:', 'private func report(')
        for forbidden in ('hncs_process_', 'ffcs_process_', '.bake(', 'toBitmap:',
                          'UIImage(', 'CGImage(', 'CVPixelBufferLockBaseAddress'):
            self.assertNotIn(forbidden, draw)

    def test_capture_mailbox_replaces_while_raw_main_queue_is_busy(self):
        mailbox = section(PROXY, 'final class LiveCameraFrameSource', 'private enum LiveProxyFailure')
        self.assertIn('private var latestFrame: LiveCameraFrame?', mailbox)
        self.assertIn('latestFrame = LiveCameraFrame(sampleBuffer:', mailbox)
        self.assertIn('let frame = latestFrame; latestFrame = nil', mailbox)
        self.assertIn('guard active, enabled, self.generation == generation', mailbox)
        self.assertIn('return active && enabled && self.generation == generation', mailbox)
        self.assertIn('if !enabled { latestFrame = nil }', mailbox)
        self.assertIn('active = false; generation &+= 1; latestFrame = nil', mailbox)
        callback = section(DELIVERY, 'func captureOutput(', 'func captureOutput(_ output: AVCaptureOutput, didDrop')
        self.assertLess(callback.index('liveSource.offer('), callback.index('guard !pending'))
        self.assertIn('video.alwaysDiscardsLateVideoFrames = true', CONTROLLER)
        self.assertNotIn('@Published', callback)

    def test_tagged_buffer_enters_color_managed_ci_without_cpu_copy(self):
        validation = section(PROXY, 'private enum LiveSourceValidation', 'struct LiveColorProxyStatus')
        for token in ('kCVPixelFormatType_420YpCbCr8BiPlanarFullRange',
                      'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange',
                      'CVPixelBufferGetPlaneCount(buffer) == 2',
                      'CMVideoFormatDescriptionMatchesImageBuffer(frame.formatDescription, imageBuffer: buffer)',
                      'CVBufferCopyAttachment(buffer, key, nil)',
                      'kCVImageBufferColorPrimariesKey', 'kCVImageBufferTransferFunctionKey',
                      'kCVImageBufferYCbCrMatrixKey', 'CMFormatDescriptionGetExtension',
                      'other != value', 'missing or conflicting camera color tags',
                      'kCVImageBufferColorPrimaries_P3_D65',
                      'kCVImageBufferTransferFunction_sRGB',
                      'kCVImageBufferChromaLocationTopFieldKey',
                      'kCVImageBufferPixelAspectRatioKey', 'raster.contains(frame.cleanRect)'):
            self.assertIn(token, validation)
        self.assertNotIn('kCVImageBufferTransferFunction_ITU_R_2100_HLG', validation)
        self.assertNotIn('kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ', validation)
        self.assertIn('horizontal.doubleValue == vertical.doubleValue', validation)
        self.assertIn('CIImage(cvPixelBuffer: frame.pixelBuffer).cropped(to: frame.cleanRect)', PROXY)
        self.assertNotIn('CIImage(cvPixelBuffer: frame.pixelBuffer, options:', PROXY)

    def test_working_shaper_cube_and_sdr_destination_contract(self):
        for token in ('view.colorPixelFormat = .rgba16Float', 'view.framebufferOnly = false',
                      'view.sampleCount = 1', 'CGColorSpace.extendedLinearSRGB',
                      '.workingFormat: CIFormat.RGBAf.rawValue',
                      'layer.wantsExtendedDynamicRangeContent = false',
                      'layer.colorspace = renderer.colorSpace',
                      'PreviewRendering.render(output, with: context, to: drawable.texture,',
                      'commandBuffer: commandBuffer, colorSpace: colorSpace'):
            self.assertIn(token, PROXY)
        draw = section(PROXY, 'func draw(in view:', 'private func report(')
        self.assertLess(draw.index('let bounded = input.applyingFilter("CIColorClamp"'),
                        draw.index('bounded.applyingFilter("CILinearToSRGBToneCurve")'))
        self.assertLess(draw.index('CILinearToSRGBToneCurve'), draw.index('filter.outputImage'))
        self.assertGreater(draw.rindex('applyingFilter("CIColorClamp"'), draw.index('filter.outputImage'))
        for forbidden in ('applyingFilter("CISRGBToneCurveToLinear"',
                          'CIFilter(name: "CIColorCubeWithColorSpace"', '.bgra8Unorm', '.RGBA8'):
            self.assertNotIn(forbidden, PROXY)

    def test_cube_filter_is_reused_but_does_not_hold_an_extra_frame(self):
        update = section(PROXY, 'func update(source:', 'fileprivate func tick()')
        draw = section(PROXY, 'func draw(in view:', 'private func report(')
        self.assertIn('CIFilter(name: "CIColorCube")', update)
        self.assertNotIn('CIFilter(name: "CIColorCube")', draw)
        self.assertIn('defer { filter.setValue(nil, forKey: kCIInputImageKey) }', draw)

    def test_drawable_is_requested_only_after_taking_a_fresh_frame(self):
        draw = section(PROXY, 'func draw(in view:', 'private func report(')
        self.assertIn('!inFlight', draw)
        self.assertLess(draw.index('source.takeLatest()'), draw.index('view.currentDrawable'))
        self.assertLess(draw.index('frame.receivedHostTime'), draw.index('view.currentDrawable'))
        self.assertIn('waitForFrame("Live color waiting for a GPU drawable', draw)
        # A second freshness check protects against a blocking drawable request.
        self.assertGreaterEqual(draw[:draw.index('queue.makeCommandBuffer')].count('frame.receivedHostTime'), 2)
        self.assertIn('view.enableSetNeedsDisplay = false', PROXY)
        self.assertIn('view.isPaused = true', PROXY)

    def test_first_success_alone_reveals_proxy_and_gpu_owns_inputs(self):
        self.assertEqual(PROXY.count('alpha = 1'), 1)
        self.assertIn('view.alpha = 0', PROXY)
        completion = section(PROXY, 'commandBuffer.addCompletedHandler', 'commandBuffer.present(drawable)')
        for token in ('[weak self, frame, cube, renderTask]', 'withExtendedLifetime(frame)',
                      'withExtendedLifetime(cube)', 'DispatchQueue.main.async',
                      'self.revision == ticket', 'self.presentationRevision == presentationTicket',
                      'source.isCurrent(frame.generation)', 'self.hasWindow',
                      'buffer.status == .error'):
            self.assertIn(token, completion)
        self.assertLess(completion.index('self.inFlight = false'), completion.index('guard self.active'))
        self.assertLess(completion.index('if failed'), completion.index('alpha = 1'))
        self.assertLess(completion.index('GPU frame expired'), completion.index('alpha = 1'))
        stop = section(PROXY, 'func stop()', 'deinit')
        self.assertNotIn('inFlight = false', stop)
        self.assertIn('inFlight = true', PROXY)

    def test_freshness_uses_monotonic_receipt_without_replacing_capture_pts(self):
        self.assertIn('self.presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)', PROXY)
        self.assertIn('self.receivedHostTime = CACurrentMediaTime()', PROXY)
        self.assertIn('maximumFrameAge: CFTimeInterval = 0.5', PROXY)
        tick = section(PROXY, 'fileprivate func tick()', 'func mtkView(')
        self.assertIn('CACurrentMediaTime() - receipt > Self.maximumFrameAge', tick)
        self.assertIn('camera frame expired', tick)
        self.assertIn('self.lastPresentedTimestamp = frame.presentationTime', PROXY)
        self.assertNotIn('CMTime(seconds:', PROXY)

    def test_offwindow_scene_pause_and_stop_clear_pending_sources(self):
        window = section(PROXY, 'fileprivate func updateWindowAvailability()', 'private func hidePresentation()')
        self.assertIn('source?.setEnabled(active && available)', window)
        self.assertIn('displayLink?.isPaused = !(active && available)', window)
        self.assertIn('hidePresentation()', window)
        self.assertIn('override func didMoveToWindow()', PROXY)
        self.assertIn('windowChanged?()', PROXY)
        self.assertIn('(view as? LiveColorProxyView)?.windowChanged = nil', PROXY)
        stop = section(PROXY, 'func stop()', 'deinit')
        for token in ('displayLink?.invalidate()', 'source?.setEnabled(false); source = nil',
                      'cubes.cancel(clearCache: true)', 'cubeFilter = nil', 'onStatus = nil'):
            self.assertIn(token, stop)
        self.assertIn('.onDisappear { camera.stop() }', VIEW)
        self.assertIn('if phase == .background { camera.stop() }', VIEW)
        self.assertIn('weak var renderer: LiveColorProxy.Renderer?', PROXY)

    def test_rotation_and_session_failures_revoke_old_gpu_generation(self):
        rotation = section(CONTROLLER, 'func updateOrientation(', 'func stop()')
        self.assertLess(rotation.index('centerLiveSource?.setEnabled(false)'),
                        rotation.index('backend.queue.async'))
        self.assertIn('liveSource.reset(generation: ticket)', DELIVERY)
        self.assertIn('liveSource.invalidate()', DELIVERY)
        failure = section(CONTROLLER, 'private func failSession(', 'private func installObservers(')
        self.assertIn('frameDeliveries.forEach { $0.freeze() }', failure)
        freeze = section(DELIVERY, 'func freeze()', 'func invalidate()')
        self.assertIn('liveSource.invalidate()', freeze)
        resize = section(PROXY, 'func mtkView(', 'func draw(in view:')
        self.assertIn('hidePresentation()', resize)
        hide = section(PROXY, 'private func hidePresentation()', 'private func waitForFrame(')
        self.assertIn('presentationRevision &+= 1', hide)
        self.assertIn('lastPresentedReceiptTime = nil', hide)
        self.assertIn('view?.alpha = 0', hide)

    def test_clean_aperture_fit_keeps_native_rotation(self):
        self.assertIn('CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: false)', PROXY)
        self.assertIn('let scale = min(size.width / aperture.width, size.height / aperture.height)', PROXY)
        self.assertIn('translationX: -aperture.minX, y: -aperture.minY', PROXY)
        self.assertIn('composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))', PROXY)
        self.assertNotIn('.oriented(', PROXY)
        self.assertNotIn('scaleY: -1', PROXY)

    def test_status_is_deduplicated_and_published_outside_swiftui_update(self):
        report = section(PROXY, 'private func report(', 'private func fail(')
        self.assertIn('guard status != lastStatus else { return }', report)
        self.assertIn('DispatchQueue.main.async', report)
        self.assertIn('self.lastStatus == status', report)
        self.assertNotIn('@Published', PROXY)

    def test_renderer_init_uses_local_values_before_super(self):
        init = section(PROXY.split('final class Renderer:', 1)[1], 'override init()', 'func attach(')
        self.assertIn('let device = MTLCreateSystemDefaultDevice()', init)
        self.assertIn('let colorSpace = CGColorSpace(name:', init)
        self.assertIn('self.device = device; self.colorSpace = colorSpace', init)
        self.assertLess(init.index('self.device ='), init.index('super.init()'))

    def test_xcode_project_compiles_the_new_source_once(self):
        # Xcode inserts object comments and expands source lists when saving
        # signing settings. Check the references independently of that layout.
        project = re.sub(r'\s+', ' ', re.sub(r'/\*.*?\*/', '', PROJECT, flags=re.S))
        ref = re.search(r'(\w+) = \{isa = PBXFileReference;[^}]*path = LiveColorProxy.swift;', project)
        self.assertIsNotNone(ref)
        ref_id = ref.group(1)
        build = re.search(r'(\w+) = \{isa = PBXBuildFile; fileRef = ' + ref_id + r'\s*;', project)
        self.assertIsNotNone(build)
        build_id = build.group(1)
        sources = re.search(r'isa = PBXSourcesBuildPhase;[^}]*files = \(([^)]*)\)', project).group(1)
        self.assertEqual(sources.count(build_id), 1)
        self.assertEqual(PROJECT.count('path = LiveColorProxy.swift;'), 1)
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 17.0', PROJECT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
