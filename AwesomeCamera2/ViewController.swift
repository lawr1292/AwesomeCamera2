//
//  ViewController.swift
//  AwesomeCamera2
//
//  Created by Ryan Law on 4/16/25.
//

import UIKit
import AVFoundation
import CoreML
import Vision

enum CameraConfigurationStatus {
    case success
    case permissionDenied
    case failed
}

public struct Box {
    public let conf: Float
    public let xywh: CGRect
    public let xywhn: CGRect
}

public struct Keypoints {
    public let xyn:[(x: Float, y: Float)]
    public let xy: [(x: Float, y: Float)]
    // public let conf:[Float]
}

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var bufferSize: CGSize = .zero
    private var camera: AVCaptureDevice?
    private var request = VNRequest()
    private let session = AVCaptureSession()
    private lazy var videoDataOutput = AVCaptureVideoDataOutput()
    var isSessionRunning: Bool = false
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private let sessionQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    private var cameraConfigurationStatus: CameraConfigurationStatus = .failed
    var highestSupportedFrameRate = 0.0
    var highestFrameRate: CMTime? = nil
    var highestQualityFormat: AVCaptureDevice.Format? = nil
    var modelInputSize = CGSize(width: 640, height: 640)
    var ourVideoRotation = CGFloat(90)
    var ourImageOrientation: CGImagePropertyOrientation = .up
    private var detectionOverlay: CALayer! = nil
    var ratio: CGFloat = 1.0
    var previewSize = CGSize(width: 0.0, height: 0.0)
    var scaleXToView:Float = 0.0
    var scaleYToView:Float = 0.0
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        attemptToStartCaptureSession()
        setUpOrientationChangeNotification()
    }
    
    private func getPermissions(completion: @escaping (Bool) -> ()) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted {
                self.cameraConfigurationStatus = .permissionDenied
            } else {
                self.cameraConfigurationStatus = .success
            }
            completion(granted)
        }
    }
    
    func updateVideoOrientation() {
      guard let connection = videoDataOutput.connection(with: .video) else { return }
        connection.videoRotationAngle = ourVideoRotation
      let currentInput = self.session.inputs.first as? AVCaptureDeviceInput
      if currentInput?.device.position == .front {
        connection.isVideoMirrored = true
      } else {
        connection.isVideoMirrored = false
      }
        let o = connection.videoRotationAngle
        self.previewLayer?.connection?.videoRotationAngle = o
        // Ensure the preview layer's frame matches the view's bounds to fill the screen.
        DispatchQueue.main.async {
            self.previewLayer?.frame = self.view.bounds
            self.setupLayers()
        }
    }
    
    private func setUpOrientationChangeNotification() {
        print("observer adad")
      NotificationCenter.default.addObserver(
        self, selector: #selector(orientationDidChange),
        name: UIDevice.orientationDidChangeNotification, object: nil)
    }
    
    private func setRotationAndImageOrientation(ori:UIDeviceOrientation){
        switch ori {
        case .portrait:
            ourVideoRotation = CGFloat(90)
            ourImageOrientation = .up
        case .portraitUpsideDown:
            ourVideoRotation = CGFloat(270)
            ourImageOrientation = .down
        case .landscapeRight:
            ourVideoRotation = CGFloat(0)
            ourImageOrientation = .right
        case .landscapeLeft:
            ourVideoRotation = CGFloat(180)
            ourImageOrientation = .left
        default:
          return
        }
    }

    @objc func orientationDidChange() {
      setRotationAndImageOrientation(ori: UIDevice.current.orientation)
      self.updateVideoOrientation()
    }
    
    func getModelInputSize(for model: MLModel) -> CGSize {
      guard let inputDescription = model.modelDescription.inputDescriptionsByName.first?.value else {
        print("can not find input description")
        return  CGSize(width:0, height:0)
      }

      if let multiArrayConstraint = inputDescription.multiArrayConstraint {
        let shape = multiArrayConstraint.shape
        if shape.count >= 2 {
          let height = shape[0].intValue
          let width = shape[1].intValue
          return CGSize(width: width, height: height)
        }
      }

      if let imageConstraint = inputDescription.imageConstraint {
        let width = Int(imageConstraint.pixelsWide)
        let height = Int(imageConstraint.pixelsHigh)
        return CGSize(width: width, height: height)
      }

      print("an not find input size")
        return CGSize(width:0, height:0)
    }
    
    private func attemptToStartCaptureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraConfigurationStatus = .success
        case .notDetermined:
            self.sessionQueue.suspend()
            self.getPermissions { granted in
                self.sessionQueue.resume()
            }
        case.denied:
            self.cameraConfigurationStatus = .permissionDenied
        default:
            break
        }
        
        self.sessionQueue.async {
            self.setupCaptureSession()
        }
    }
    
    private func setupCaptureSession() {
        session.beginConfiguration()
        setupInput()
        setupOutput()
        session.commitConfiguration()
        setupVision()
        setupPreviewLayer()
    }
    
    private func startCaptureSession() {
        sessionQueue.async {
            if self.cameraConfigurationStatus == .success {
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
    }
    
    private func stopSession() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.session.stopRunning()
                self.isSessionRunning = false
            }
        }
        
        DispatchQueue.main.async {
            self.previewLayer.removeFromSuperlayer()
            self.previewLayer = nil
        }
    }
    
    private func setupInput() {
        var deviceInput: AVCaptureDeviceInput!
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTripleCamera, .builtInTelephotoCamera, .builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera], mediaType: .video, position: .front)
        
        var highestQualityDevice: AVCaptureDevice?
        session.sessionPreset = .high
        
        for device in discoverySession.devices.reversed() {
            // print("Device: \(device)")
            for format in device.formats {
                if(format.isHighestPhotoQualitySupported){
                    //print("is highest photo quality supported: \(format.isHighestPhotoQualitySupported)")
                    //print("is merely high photo quality supported: \(format.isHighPhotoQualitySupported)")
                    //print("Supported max photo dims: \(format.supportedMaxPhotoDimensions)")
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate > highestSupportedFrameRate {
                            highestSupportedFrameRate = range.maxFrameRate
                            highestQualityDevice = device
                            highestQualityFormat = format
                            highestFrameRate = CMTime(value: 1, timescale: CMTimeScale(range.maxFrameRate))
                        }
                    }
                }
            }
        }
        
        camera = highestQualityDevice
        print("Device chosen: \(String(describing: highestQualityDevice))")
        guard let camera = camera else {
            print("No camera available")
            return
        }
                
        do {
            deviceInput = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
            } else {
                print("Could not add input")
                return
            }
        } catch {
            fatalError("Cannot create video device input")
        }
    }
    
    private func setupOutput() {
        let sampleBufferQueue = DispatchQueue(label: "SampleBufferQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_32BGRA]
        setRotationAndImageOrientation(ori: UIDevice.current.orientation)

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        } else {
            print("Output setup error")
        }
        
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        connection.videoRotationAngle = ourVideoRotation
        let currentInput = self.session.inputs.first as? AVCaptureDeviceInput
        if currentInput?.device.position == .front {
          connection.isVideoMirrored = true
        } else {
          connection.isVideoMirrored = false
        }
        do {
            try camera?.lockForConfiguration()
            if let format = highestQualityFormat {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                bufferSize.width = CGFloat(dimensions.width)
                bufferSize.height = CGFloat(dimensions.height)
                camera?.activeFormat = format
                camera?.activeVideoMinFrameDuration = highestFrameRate!
                camera?.activeVideoMaxFrameDuration = highestFrameRate!
            }
            camera?.unlockForConfiguration()
        } catch {
            print("Error setting format or dimensions")
        }
    }
    
    private func setupPreviewLayer() {
        DispatchQueue.main.async {
            self.previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
            self.previewLayer.frame = self.view.bounds
            self.previewLayer.videoGravity = .resizeAspectFill
            //self.previewLayer.connection?.videoRotationAngle = self.ourVideoRotation
            self.view.layer.addSublayer(self.previewLayer)
            self.setupLayers()
            self.startCaptureSession()
        }
    }
    
    func setupLayers() {
        detectionOverlay = CALayer() // container layer that has all the renderings of the observations
        detectionOverlay.name = "DetectionOverlay"
        detectionOverlay.bounds = CGRect(x: 0.0,
                                         y: 0.0,
                                         width: self.view.bounds.width,
                                         height: self.view.bounds.height)
        detectionOverlay.position = CGPoint(x: previewLayer.bounds.midX, y: previewLayer.bounds.midY)
        previewLayer.addSublayer(detectionOverlay)
        self.previewSize = self.view.bounds.size
        if session.sessionPreset == .photo {
            ratio = (previewSize.height / previewSize.width) / (4.0 / 3.0)
        } else {
            ratio = (previewSize.height / previewSize.width) / (16.0 / 9.0)
        }
        print("Preview size: \(self.previewSize)")
        print("Ratio: \(ratio)")
    }
    
    private func setupVision() -> NSError? {
        let error: NSError! = nil
        guard let unwrappedModelURL = Bundle.main.url(forResource: "best_yolo", withExtension: "mlmodelc") else {
            print("Model file is missing1")
            return NSError(domain: "VisionObjectRecognitionViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
        }
        let ext = unwrappedModelURL.pathExtension.lowercased()
        let isCompiled = (ext == "mlmodelc")
        let config = MLModelConfiguration()
        if #available(iOS 16.0, *) {
          config.setValue(1, forKey: "experimentalMLE5EngineUsage")
        }
        do {
            let mlModel: MLModel
            if isCompiled {
                mlModel = try MLModel(contentsOf: unwrappedModelURL, configuration: config)
            } else {
                let compiledUrl = try MLModel.compileModel(at: unwrappedModelURL)
                mlModel = try MLModel(contentsOf: compiledUrl, configuration: config)
            }
            
            guard
                let userDefined = mlModel.modelDescription
                    .metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
            else {
                return NSError(domain: "VisionObjectRecognitionViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
            }
            self.modelInputSize = getModelInputSize(for: mlModel)
            
            let detector = try VNCoreMLModel(for: mlModel)
            
            request = {
                let request = VNCoreMLRequest(
                  model: detector,
                  completionHandler: {
                    (request, error) in
                      self.processObservations(for: request, error: error)
                  })
                request.imageCropAndScaleOption = .scaleFill
                return request
              }()
        } catch let error as NSError {
            print("model loading went wrong: \(error)")
        }
        
        return error
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection:AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("failed to get samplebuffer")
            return
        }
        let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let frameSize = CGSize(width: frameWidth, height: frameHeight)
        /// - Tag: MappingOrientation From ULTRALYTICS/yolo-ios-app/Sources/YOLO/BasePredictor.swift
        // The frame is always oriented based on the camera sensor,
        // so in most cases Vision needs to rotate it for the model to work as expected.
        // let imageOrientation: CGImagePropertyOrientation = .up
        
        // detection overlay size is same as preview size
        // buffer size is same as frame size to be detected preview size: \(previewLayer.bounds.size),
        print("detection size: \(detectionOverlay.bounds.size), buffer size: \(bufferSize), image size: \(frameSize)")
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try imageRequestHandler.perform([self.request])
        } catch {
            print("Failed to preform vision request: \(error)")
        }
    }
    
    func processObservations(for request: VNRequest, error: Error?) {
        if let results = request.results as? [VNCoreMLFeatureValueObservation] {
            
            if let prediction = results.first?.featureValue.multiArrayValue {
//                
//                //            let preds = PostProcessPose(
//                //              prediction: prediction, confidenceThreshold: Float(self.confidenceThreshold),
//                //              iouThreshold: Float(self.iouThreshold))
//                var keypointsList = [Keypoints]()
//                var boxes = [Box]()
                let poses = self.postProcessPose(prediction: prediction)
                //print("Poses: \(poses.count)")
                if !(poses.count == 0) {
                    self.drawVisionRequestResult(poses)
                } else {
                    CATransaction.begin()
                    CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
                    self.detectionOverlay?.sublayers = nil
                    CATransaction.commit()
                }
            } else {
                print("non prediction?")
            }
        }
    }
    
    func postProcessPose(
      prediction: MLMultiArray,
      confidenceThreshold: Float = 0.35,
      iouThreshold: Float = 0.5
    )
      -> [(box: Box, keypoints: Keypoints)]
    {
      let numAnchors = prediction.shape[2].intValue
      let featureCount = prediction.shape[1].intValue - 5

      var boxes = [CGRect]()
      var scores = [Float]()
      var features = [[Float]]()

      let featurePointer = UnsafeMutablePointer<Float>(OpaquePointer(prediction.dataPointer))
      let lock = DispatchQueue(label: "com.example.lock")
      //print("hi1")
      DispatchQueue.concurrentPerform(iterations: numAnchors) { j in
        let confIndex = 4 * numAnchors + j
        let confidence = featurePointer[confIndex]

        if confidence > confidenceThreshold {
          let x = featurePointer[j]
          let y = featurePointer[numAnchors + j]
          let width = featurePointer[2 * numAnchors + j]
          let height = featurePointer[3 * numAnchors + j]

          let boxWidth = CGFloat(width)
          let boxHeight = CGFloat(height)
          let boxX = CGFloat(x - width / 2.0)
          let boxY = CGFloat(y - height / 2.0)
          let boundingBox = CGRect(
            x: boxX, y: boxY,
            width: boxWidth, height: boxHeight)

          var boxFeatures = [Float](repeating: 0, count: featureCount)
          for k in 0..<featureCount {
            let key = (5 + k) * numAnchors + j
            boxFeatures[k] = featurePointer[key]
          }

          lock.sync {
            boxes.append(boundingBox)
            scores.append(confidence)
            features.append(boxFeatures)
          }
        }
      }

      let selectedIndices = nonMaxSuppression(boxes: boxes, scores: scores, threshold: iouThreshold)

      let filteredBoxes = selectedIndices.map { boxes[$0] }
      let filteredScores = selectedIndices.map { scores[$0] }
      let filteredFeatures = selectedIndices.map { features[$0] }

      let boxScorePairs = zip(filteredBoxes, filteredScores)
      let results: [(Box, Keypoints)] = zip(boxScorePairs, filteredFeatures).map {
        (pair, boxFeatures) in
        let (box, score) = pair
        let Nx = box.origin.x / CGFloat(modelInputSize.width)
        let Ny = box.origin.y / CGFloat(modelInputSize.height)
        let Nw = box.size.width / CGFloat(modelInputSize.width)
        let Nh = box.size.height / CGFloat(modelInputSize.height)
          let ix = Nx * bufferSize.width
          let iy = Ny * bufferSize.height
          let iw = Nw * bufferSize.width
          let ih = Nh * bufferSize.height
        let normalizedBox = CGRect(x: Nx, y: Ny, width: Nw, height: Nh)
        let imageSizeBox = CGRect(x: ix, y: iy, width: iw, height: ih)
        let boxResult = Box(
         conf: score, xywh: imageSizeBox, xywhn: normalizedBox)
        let numKeypoints = boxFeatures.count / 2

        var xynArray = [(x: Float, y: Float)]()
        var xyArray = [(x: Float, y: Float)]()
        var confArray = [Float]()

        for i in 0..<numKeypoints {
          let kx = boxFeatures[2 * i]
          let ky = boxFeatures[2 * i + 1]
          //let kc = boxFeatures[3 * i + 2]

          let nX = kx / Float(modelInputSize.width)
          let nY = ky / Float(modelInputSize.height)
          xynArray.append((x: nX, y: nY))

            let x = nX * Float(bufferSize.width)
            let y = nY * Float(bufferSize.height)
          xyArray.append((x: x, y: y))

          //confArray.append(kc)
        }

        let keypoints = Keypoints(xyn: xynArray, xy: xyArray/*, conf: confArray*/)
        return (boxResult, keypoints)
      }

      return results
    }

    
//    func postProcessPose(prediction: MLMultiArray, confidenceThreshold: Float = 0.35) -> [(box: Box, keypoints: Keypoints)] {
//            let numAnchors = prediction.shape[2].intValue
//            let featureCount = prediction.shape[1].intValue - 5
//            var boxes = [CGRect]()
//            var scores = [Float]()
//            var features = [[Float]]()
//            //print("num anchors: \(numAnchors)")
//            //print("num features: \(featureCount)")
//            let featurePointer = UnsafeMutablePointer<Float>(OpaquePointer(prediction.dataPointer))
//            let lock = DispatchQueue(label: "com.example.lock")
//
//            DispatchQueue.concurrentPerform(iterations: numAnchors) { j in
//                //print("j: \(j)")
//                let confIndex = 4 * numAnchors + j
//                let confidence = featurePointer[confIndex]
//                //print("confindex: \(confIndex)")
//                //print("confidence: \(confidence)")
//
//                if confidence > confidenceThreshold {
//                    // this j has enough confidence. prediction shape: (1, 21, 1029)
//                    // think of prediction as a matrix where each row is representative of a different feature (boxpiece or pointpiece)
//                    // feature pointer can be thought of as a 1D array of our matrix.
//                    // the stride is numAnchors is 1029
//                    // so the next feature is obtained by striding up to where the next set of features is held
//                    let x = featurePointer[j]
//                    let y = featurePointer[numAnchors + j]
//                    let width = featurePointer[2 * numAnchors + j]
//                    let height = featurePointer[3 * numAnchors + j]
//
//                    // make cgrect
//                    let boxWidth = CGFloat(width)
//                    let boxHeight = CGFloat(height)
//                    let boxX = CGFloat(x - width / 2.0)
//                    let boxY = CGFloat(y - height / 2.0)
//                    let boundingBox = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
//
//                    // points in box
//                    var boxFeatures = [Float](repeating: 0, count: featureCount)
//                    // feature count is 16 (2*8) add 5 for x,y,w,h,c multiply by the stride and add the index
//                    for k in 0..<featureCount {
//                        let key = (5 + k) * numAnchors + j
//                        boxFeatures[k] = featurePointer[key]
//                    }
//
//                    lock.sync {
//                        boxes.append(boundingBox)
//                        scores.append(confidence)
//                        features.append(boxFeatures)
//                    }
//                }
//            }
//
//            let selectedIndices = nonMaxSuppression(boxes: boxes, scores: scores, threshold: 0.35)
//
//            let filteredBoxes = selectedIndices.map { boxes[$0] }
//            let filteredScores = selectedIndices.map { scores[$0] }
//            let filteredFeatures = selectedIndices.map { features[$0] }
//            //print("filtered boxes count: \(filteredBoxes.count)")
//            let boxScorePairs = zip(filteredBoxes, filteredScores)
//            let results: [(Box, Keypoints)] = zip(boxScorePairs, filteredFeatures).map { (pair, boxFeatures) in
//                let (box, score) = pair
//                let Nx = box.origin.x / CGFloat(modelInputSize.width)
//                let Ny = box.origin.y / CGFloat(modelInputSize.height)
//                let Nw = box.size.width / CGFloat(modelInputSize.width)
//                let Nh = box.size.height / CGFloat(modelInputSize.height)
//                let ix = Nx * bufferSize.width
//                let iy = Ny * bufferSize.height
//                let iw = Nw * bufferSize.width
//                let ih = Nh * bufferSize.height
//                let normalizedBox = CGRect(x: Nx, y: Ny, width: Nw, height: Nh)
//                let imageSizeBox = CGRect(x: ix, y: iy, width: iw, height: ih)
//                let boxResult = Box(conf: score, xywh: imageSizeBox, xywhn: normalizedBox)
//                let numKeypoints = boxFeatures.count / 2  // Adjusted for the correct number of keypoints
//                var xynArray = [(x: Float, y: Float)]()
//                var xyArray = [(x: Float, y: Float)]()
//                var confArray = [Float]()
//
//                for i in 0..<numKeypoints {
//                    let kx = boxFeatures[2 * i]
//                    let ky = boxFeatures[2 * i + 1]
//                    
//                    let nX = kx / Float(modelInputSize.width)
//                    let nY = ky / Float(modelInputSize.height)
//                    xynArray.append((x: nX, y: nY))
//                    
//                    let x = nX * Float(bufferSize.width)
//                    let y = nY * Float(bufferSize.height)
//                    xyArray.append((x: x, y: y))
//                    
//                    confArray.append(1.0) // Assuming confidence of 1.0 for each keypoint
//                }
//
//                let keypoints = Keypoints(xyn: xynArray, xy: xyArray, conf: confArray)
//                return (boxResult, keypoints)
//            }
//
//            return results
//        }
//    
    public func nonMaxSuppression(boxes: [CGRect], scores: [Float], threshold:Float) -> [Int] {
        let sortedIndicies = scores.enumerated().sorted { $0.element > $1.element }.map { $0.offset }
        
        var selectedIndicies = [Int]()
        var activeIndicies = [Bool](repeating: true, count: boxes.count)
        
        for i in 0..<sortedIndicies.count {
            let idx = sortedIndicies[i]
            if activeIndicies[idx] {
                selectedIndicies.append(idx)
                for j in i + 1..<sortedIndicies.count {
                    let otherIdx = sortedIndicies[j]
                    if activeIndicies[otherIdx] {
                        let intersection = boxes[idx].intersection(boxes[otherIdx])
                        if intersection.area > CGFloat(threshold) * min(boxes[idx].area, boxes[otherIdx].area) { activeIndicies[otherIdx] = false }
                    }
                }
            }
        }
        return selectedIndicies
    }
    
    
    public func drawVisionRequestResult(_ results: [(box: Box, keypoints: Keypoints)]) {
        var drawings:[CGRect] = []
        //print("Box left-side: \(results[0].box.xywhn.minX)")
        for result in results {
            var box = result.box.xywhn
//            if ratio >= 1 {
//                let offset = (1 - ratio) * (0.5 - box.minX)
////                let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: offset, y: -1)
////                box = box.applying(transform)
//                let transform = CGAffineTransform(translationX: offset, y: 0)
//                box = box.applying(transform)
//                box.size.width *= ratio
//              } else {
////                  let offset = (ratio - 1) * (0.5 - box.maxY)
////                  let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: offset - 1)
////                  box = box.applying(transform)
//                  let offset = (ratio - 1) * (0.5 - box.minY)
//                  let transform = CGAffineTransform(translationX: 0, y: offset)
//                  box = box.applying(transform)
//                //ratio = (previewSize.height / previewSize.width) / (3.0 / 4.0)
//                  box.size.height /= ratio
//              }
//            box = VNImageRectForNormalizedRect(box, Int(previewSize.width), Int(previewSize.height))
            box = previewLayer.layerRectConverted(fromMetadataOutputRect: box)
            print(box)
            drawings.append(box)
        }
        
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        detectionOverlay?.sublayers = nil
        for drawing in drawings {
            let shapeLayer = createRoundedRectLayerWithBounds(drawing)
            detectionOverlay?.addSublayer(shapeLayer)
        }
        
        for kp in results {
            let kpDrawing = createDotLayers(kp.keypoints)
            for layer in kpDrawing {
                detectionOverlay?.addSublayer(layer)
            }
        }
        // self.updateLayerGeometry()
        CATransaction.commit()
    }

    func createDotLayers(_ kps: Keypoints) -> [CAShapeLayer] {
        var layers: [CAShapeLayer] = []
        
        for dot in kps.xyn {
            let landmarkLayer = CAShapeLayer()
            let color: CGColor = UIColor.systemTeal.cgColor
            let stroke: CGColor = UIColor.yellow.cgColor
            landmarkLayer.fillColor = color
            landmarkLayer.strokeColor = stroke
            landmarkLayer.lineWidth = 2.0

            var center = CGPoint(
                x: CGFloat(dot.x),
                y: CGFloat(dot.y)
            )
            center = previewLayer.layerPointConverted(fromCaptureDevicePoint: center)
            let radius: CGFloat = 5.0 // Adjust this as needed.
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            landmarkLayer.path = UIBezierPath(ovalIn: rect).cgPath
            layers.append(landmarkLayer)
        }
        return layers
    }
    
    func createRoundedRectLayerWithBounds(_ bounds: CGRect) -> CALayer {
        let shapeLayer = CALayer()
        shapeLayer.bounds = bounds
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.name = "Found Object"
        shapeLayer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 0.5, 0.2, 0.4])
        shapeLayer.cornerRadius = 3
        return shapeLayer
    }
}

extension CGRect {
    var area: CGFloat { return width * height }
}

//extension CIImage {
//    func resize(to size: CGSize) -> CIImage? {
//        let scaleX = size.width / extent.size.width
//        let scaleY = size.height / extent.size.height
//        return transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
//    }
//}
