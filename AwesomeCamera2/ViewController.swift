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
    public let xywh: Float
    public let nxywh: Float
}

public struct Keypoints {
    public let xyn:[(x: Float, y: Float)]
    public let xy: [(x: Float, y: Float)]
    public let conf:[Float]
}

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var bufferSize: CGSize = .zero
    private var camera: AVCaptureDevice?
    private var requests = [VNRequest]()
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
        //setupPreviewLayer()
    }
    
    private func setUpOrientationChangeNotification() {
        print("observer adad")
      NotificationCenter.default.addObserver(
        self, selector: #selector(orientationDidChange),
        name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc func orientationDidChange() {
      switch UIDevice.current.orientation {
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
      self.updateVideoOrientation()
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
        //setupVision()
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
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        } else {
            print("Output setup error")
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
            self.view.layer.addSublayer(self.previewLayer)
            self.startCaptureSession()
        }
    }
    
}

