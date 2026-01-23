import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class HomePage extends StatefulWidget {
  final CameraDescription cameraDescription;
  const HomePage({super.key, required this.cameraDescription});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Get user preferences from SharedPreferences to determine timelapse speed
  Future<void> getUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString("SelectedValue");
    setState(() {
      timelapseType = data ?? 'slow';
    });
    print("User SelectedData=$data");
  }

  // Request necessary permissions for camera and gallery access
  // Different permissions required for different Android versions and iOS
  Future<void> requestPermission() async {
    try {
      if (Platform.isAndroid) {
        // For Android 13+, we need to request specific media permissions
        if (await Permission.photos.isDenied) {
          await Permission.photos.request();
        }
        if (await Permission.videos.isDenied) {
          await Permission.videos.request();
        }
        // For older Android versions, request storage permission
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      } else if (Platform.isIOS) {
        // For iOS, request photos permission which covers both photos and videos
        if (await Permission.photos.isDenied) {
          await Permission.photos.request();
        }
      }
    } catch (e) {
      print("Error requesting permissions: $e");
    }
  }

  // Camera controller helps in controlling the camera hardware like preview images, take photos
  // and also for accessing the camera. We need camera controller to interact with device camera
  late CameraController cameraController;
  Future<void>? initializeControllerFuture;

  // Timer is a kind of a data type that is used to execute the code after some time
  // when the timer time goes out. We use this to capture images at regular intervals
  Timer? captureTimer;

  // Track the number of images captured in current session
  int _imageCount = 0;

  // Flag to track if we're currently recording a timelapse
  bool _isRecording = false;

  // Flag to track if we're currently processing/generating the video
  bool _isProcessing = false;

  // Store the type of timelapse: 'fast' or 'slow'
  String timelapseType = "";

  // Session Id is used to uniquely identify the images that are captured in one session
  // or for one timelapse and then group them together to form one video.
  // This prevents mixing images from different recording sessions
  String? sessionId;

  // For storing the paths of all captured images in current session
  List<String> capturedVideosPath = [];

  // Video player controller for playing the generated timelapse video
  VideoPlayerController? videoPlayerController;

  // Store the final generated video path
  String? _generatedVideoPath;

  // Store the path of the latest captured image to show as preview thumbnail
  String? _latestImagePath;

  @override
  void initState() {
    super.initState();

    // Initialize all necessary components when widget is created
    _initializeApp();
  }

  // Initialize the app by loading preferences, requesting permissions, and setting up camera
  Future<void> _initializeApp() async {
    await getUserPreferences();
    await requestPermission();
    // Initialize camera settings with high resolution preset
    cameraController = CameraController(
      widget.cameraDescription,
      ResolutionPreset.high,
    );
    initializeControllerFuture = cameraController.initialize();
  }

  // Get the interval between image captures based on timelapse type
  // Fast mode: 500ms intervals, Slow mode: 5 second intervals
  Duration _getCaptureTimingsIntervals() {
    return timelapseType == 'fast'
        ? const Duration(milliseconds: 500)
        : const Duration(seconds: 5);
  }

  // Get the frame rate for the final video output
  // Returns frames per second (FPS) for the generated video
  int _getFrameVideoRates() {
    return 30;
  }

  // Start the timelapse recording process
  Future<void> startTimeLapse() async {
    // Clear any previous session data
    capturedVideosPath.clear();

    // Assigning the unique id to the images so that it is uniquely used to combine
    // the images and then form a video. Using timestamp ensures uniqueness
    sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    setState(() {
      _isRecording = true;
      _imageCount = 0;
      _generatedVideoPath = null;
      _latestImagePath = null;
    });

    // Dispose the previous video controller if it exists to free up resources
    await videoPlayerController?.dispose();
    videoPlayerController = null;

    // Set up periodic timer to capture images at specified intervals
    final interval = _getCaptureTimingsIntervals();
    captureTimer = Timer.periodic(interval, (timer) async {
      await _captureImage();
    });
  }

  // Stop the timelapse recording and show dialog to generate video
  void _stopTimeLapse() {
    // Cancel the periodic timer to stop capturing images
    captureTimer?.cancel();
    setState(() {
      _isRecording = false;
    });

    // If we have captured images, ask user if they want to generate video
    if (capturedVideosPath.isNotEmpty) {
      _showGenerateVideoDialog();
    }
  }

  // Capture a single image and save it to the session directory
  Future<void> _captureImage() async {
    try {
      // Wait for camera to be fully initialized before capturing
      await initializeControllerFuture;

      // Get the app's document directory for storing images
      final directory = await getApplicationDocumentsDirectory();

      // This is for the path which will be used to store the multiple images for timelapse
      // Each session gets its own directory with unique session ID
      final sessionDir = Directory(
        path.join(directory.path, 'timelapse_${timelapseType}_$sessionId'),
      );

      // Create the session directory if it doesn't exist
      if (!await sessionDir.exists()) {
        await sessionDir.create(recursive: true);
      }

      // For sorting the captured images in the correct order
      // Padding with zeros ensures proper alphabetical/numerical sorting (e.g., 00001, 00002, etc.)
      final paddedCount = _imageCount.toString().padLeft(5, '0');
      final imagePath = path.join(sessionDir.path, 'frame_$paddedCount.jpg');

      // Take the picture using camera controller
      final image = await cameraController.takePicture();

      // Temporary holding the image path and used for copying like when we capture the image
      // it needs some space where it would store the image. If not stored, the image the OS
      // might delete some apps to clear up the space. So we copy to permanent location
      await File(image.path).copy(imagePath);

      // Verify the file was actually created and get its size for logging
      final savedFile = File(imagePath);
      if (await savedFile.exists()) {
        final fileSize = await savedFile.length();
        print(
          "Captured image $_imageCount at $imagePath (size: $fileSize bytes)",
        );

        // Adding the image path to the videos path list
        capturedVideosPath.add(imagePath);
        setState(() {
          _imageCount++;
          _latestImagePath =
              imagePath; // Update latest image for preview thumbnail
        });
      } else {
        print("Warning: Image file was not created at $imagePath");
      }
    } catch (e) {
      print("Error capturing image: $e");
    }
  }

  // Show dialog asking user if they want to generate video from captured images
  void _showGenerateVideoDialog() {
    showDialog(
      context: context,
      barrierDismissible:
          false, // User must make a choice, can't dismiss by tapping outside
      builder: (context) => AlertDialog(
        title: const Text("TimeLapse Complete"),
        content: Text('Captured $_imageCount images. Generate video now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _generateVideo();
            },
            child: const Text("Generate Video"),
          ),
        ],
      ),
    );
  }

  // Now after capturing the images, compile all the images to form a timelapse video
  // This uses FFmpeg to stitch together all captured images into a video file
  Future<void> _generateVideo() async {
    // Safety check: ensure we have images to process
    if (capturedVideosPath.isEmpty) {
      _showSnackBar("No images to process");
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Get directory to save the output video
      final directory = await getApplicationDocumentsDirectory();
      final outputPath = path.join(
        directory.path,
        'timelapse_${timelapseType}_$sessionId.mp4',
      );

      // For giving me the directory name where all the images are stored
      final sessionDir = path.dirname(capturedVideosPath.first);
      final frameRate = _getFrameVideoRates();

      // Use sequential pattern for FFmpeg input - %05d means 5-digit padded numbers
      final inputPattern = path.join(sessionDir, 'frame_%05d.jpg');

      // Now run the FFmpeg command to create video from images
      // -framerate: sets input frame rate
      // -i: input pattern
      // -c:v libx264: use H.264 codec for video encoding
      // -pix_fmt yuv420p: pixel format for compatibility
      // -preset ultrafast: encoding speed (faster = larger file)
      // -y: overwrite output file if it exists
      final command =
          '-framerate $frameRate -i "$inputPattern" -c:v libx264 -pix_fmt yuv420p -preset ultrafast -y "$outputPath"';

      print('FFmpeg command: $command');
      print('Session directory: $sessionDir');
      print('Output path: $outputPath');
      print('Total images: ${capturedVideosPath.length}');

      // Execute FFmpeg command and handle the result
      await FFmpegKit.execute(command).then((session) async {
        final returnCode = await session.getReturnCode();
        final output = await session.getOutput();

        print('Return code: $returnCode');
        print('Output: $output');

        // Check if FFmpeg execution was successful
        if (ReturnCode.isSuccess(returnCode)) {
          print("Video Generated Successfully at: $outputPath");

          // Verify the video file actually exists and check its size
          final videoFile = File(outputPath);
          if (await videoFile.exists()) {
            final fileSize = await videoFile.length();
            print('Video file size: $fileSize bytes');

            setState(() {
              _generatedVideoPath = outputPath;
              _isProcessing = false;
            });

            // Initialize video player to play the generated video
            await _initializeVideoPlayer(outputPath);

            // Save the generated video to device gallery
            await _saveVideoToGallery(outputPath);

            if (mounted) {
              _showSnackBar("Timelapse video created and saved to gallery!");
            }
          } else {
            throw Exception('Video file was not created');
          }
        } else {
          // FFmpeg failed - log the error details
          final failStackTrace = await session.getFailStackTrace();
          print('FFmpeg failed with return code: $returnCode');
          print('Fail stack trace: $failStackTrace');

          setState(() {
            _isProcessing = false;
          });

          if (mounted) {
            _showSnackBar('Failed to generate video. Code: $returnCode');
          }
        }
      });
    } catch (e) {
      print('Error generating video: $e');
      setState(() {
        _isProcessing = false;
      });

      if (mounted) {
        _showSnackBar('Error: $e');
      }
    }
  }

  // Initialize the video player with the generated video file
  Future<void> _initializeVideoPlayer(String videoPath) async {
    try {
      videoPlayerController = VideoPlayerController.file(File(videoPath));
      await videoPlayerController!.initialize();
      setState(() {}); // Rebuild UI to show video player
    } catch (e) {
      print('Error initializing video player: $e');
    }
  }

  // Save the generated video to device gallery so user can access it from Photos/Gallery app
  Future<void> _saveVideoToGallery(String videoPath) async {
    try {
      // First check if we have access to save to gallery
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          print("Gallery access denied");
          return;
        }
      }

      // Save video to gallery with custom album name
      await Gal.putVideo(videoPath, album: 'TimeLapse Videos');
      print("Video saved to gallery successfully");
    } catch (e) {
      print("Error saving video to gallery: $e");
      if (mounted) {
        _showSnackBar("Video created but couldn't save to gallery");
      }
    }
  }

  // Helper method to show snackbar messages to user
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    // Clean up resources when widget is disposed
    captureTimer?.cancel(); // Cancel any running timer
    cameraController.dispose(); // Release camera resources
    videoPlayerController?.dispose(); // Release video player resources
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Timelapse - ${timelapseType.toUpperCase()}'),
        backgroundColor: Colors.deepPurple,
        elevation: 0,
      ),
      body: FutureBuilder<void>(
        future: initializeControllerFuture,
        builder: (context, snapshot) {
          // Show loading indicator while camera is initializing
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      // Main preview area - shows either camera preview or generated video
                      _generatedVideoPath != null &&
                              videoPlayerController != null
                          ? _buildVideoPreview()
                          : CameraPreview(cameraController),

                      // Latest image thumbnail - shown in top-right corner during recording
                      // This gives visual feedback of what's being captured
                      if (_isRecording && _latestImagePath != null)
                        Positioned(
                          top: 16,
                          right: 16,
                          child: _buildLatestImageThumbnail(),
                        ),

                      // Recording indicator badge - shown in top-left corner during recording
                      if (_isRecording)
                        Positioned(
                          top: 16,
                          left: 16,
                          child: _buildRecordingIndicator(),
                        ),
                    ],
                  ),
                ),
                // Control panel at bottom with stats and buttons
                _buildControlPanel(),
              ],
            );
          } else {
            // Show loading spinner while camera initializes
            return const Center(
              child: CircularProgressIndicator(color: Colors.deepPurple),
            );
          }
        },
      ),
    );
  }

  // Build the recording indicator badge that appears during recording
  Widget _buildRecordingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pulsing white dot to indicate active recording
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'RECORDING',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // Widget to show the latest captured image as a thumbnail in the corner
  // This provides visual feedback to user showing what's being captured
  Widget _buildLatestImageThumbnail() {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 3),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Display the latest captured image
            Image.file(
              File(_latestImagePath!),
              fit: BoxFit.cover,
              // Show broken image icon if image fails to load
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: Colors.grey[800],
                  child: const Icon(Icons.broken_image, color: Colors.white),
                );
              },
            ),
            // Overlay at bottom showing current frame count
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                color: Colors.black.withOpacity(0.7),
                child: Text(
                  'Frame $_imageCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build video preview with play/pause controls after video is generated
  Widget _buildVideoPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Video player centered on screen
        Center(
          child: AspectRatio(
            aspectRatio: videoPlayerController!.value.aspectRatio,
            child: VideoPlayer(videoPlayerController!),
          ),
        ),
        // Control buttons overlay at bottom
        Positioned(
          bottom: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Play/Pause button
              Container(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: IconButton(
                  onPressed: () {
                    setState(() {
                      videoPlayerController!.value.isPlaying
                          ? videoPlayerController!.pause()
                          : videoPlayerController!.play();
                    });
                  },
                  icon: Icon(
                    videoPlayerController!.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // Button to start new recording session
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _generatedVideoPath = null;
                    videoPlayerController?.dispose();
                    videoPlayerController = null;
                  });
                },
                icon: const Icon(Icons.camera_alt),
                label: const Text('New Recording'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Build the control panel at bottom showing stats and control buttons
  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black87,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Show processing indicator when generating video
          if (_isProcessing)
            const Column(
              children: [
                CircularProgressIndicator(color: Colors.deepPurple),
                SizedBox(height: 10),
                Text(
                  'Generating video and saving to gallery...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            )
          else ...[
            // Stats row showing images captured, interval, and output FPS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatColumn('Images Captured', '$_imageCount'),
                _buildStatColumn(
                  'Interval',
                  '${_getCaptureTimingsIntervals().inMilliseconds / 1000}s',
                ),
                _buildStatColumn('Output FPS', '${_getFrameVideoRates()}'),
              ],
            ),
            const SizedBox(height: 20),
            // Control buttons row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Start button - disabled when recording or video is generated
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ElevatedButton.icon(
                      onPressed: _isRecording || _generatedVideoPath != null
                          ? null
                          : startTimeLapse,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                // Stop button - only enabled when recording
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ElevatedButton.icon(
                      onPressed: _isRecording ? _stopTimeLapse : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                // Make Video button - shown only when we have captured images and not recording
                if (capturedVideosPath.isNotEmpty && !_isRecording)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ElevatedButton.icon(
                        onPressed: _generateVideo,
                        icon: const Icon(Icons.video_library),
                        label: const Text('Make Video'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // Helper widget to build a stat column showing label and value
  Widget _buildStatColumn(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
