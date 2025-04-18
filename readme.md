YOLO Pose Estimator mobile camera app
Meant to be used with any pose estimator
The commented out PostProcessPose() function is meant to handle 2-valued features
 - to be used for custom models if needed (like best11n-pose)
 The other PostProcessPose() function is meant to handle 3-valued features, this is the only difference between the two

The keypoints projected onto the preview feel slightly off in the scaling and the ultralytics example app handles it better still. 
