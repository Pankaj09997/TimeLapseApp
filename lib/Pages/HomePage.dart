import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as path;

class HomePage extends StatefulWidget {
  final CameraDescription cameraDescription;
  const HomePage({super.key, required this.cameraDescription});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<void> getUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString("SelectedValue");
    setState(() {
      timelapseType = data ?? 'slow';
    });
    print("User SelectedData=$data");
  }

  // camera controller helps in controlling the camera hardware like preview images, take photos
  late CameraController cameraController;
  late Future<void> initializeControllerFuture;
  //Timer is a kind of a data type that is used to execute the code after some time when the timer time goes out.
  Timer? captureTimer;
  int _imageCount = 0;
  bool _isRecording = false;
  bool _isProcessing = false;
  String timelapseType = "";
  // session Id is used to uniquely identify the images that are captured in one session or for one timelapse and then group them together to form one video.
  String? sessionId;
  //for storing the path of the video
  List<String> capturedVideosPath = [];
  VideoPlayerController? videoPlayerController;
  String? _generatedVideoPath;

  @override
  void initState() {
    super.initState();
    getUserPreferences();
    // initiazed the settings
    cameraController = CameraController(
      widget.cameraDescription,
      ResolutionPreset.high,
    );
    initializeControllerFuture = cameraController.initialize();
  }

  Duration _getCaptureTimingsIntervals() {
    return timelapseType == 'fast'
        ? const Duration(milliseconds: 500)
        : const Duration(seconds: 5);
  }

  int _getFrameVideoRates() {
    return 30;
  }

  Future<void> startTimeLapse() async {
    capturedVideosPath.clear();
    // assigning the unique id to the images so that it is uniquely used to combine the images and then form a video
    sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _isRecording = true;
      _imageCount = 0;
      _generatedVideoPath = null;
    });
    // dispose the previous video controller if it exists
    await videoPlayerController?.dispose();
    videoPlayerController = null;
    final interval = _getCaptureTimingsIntervals();
    captureTimer = Timer.periodic(interval, (timer) async {
      await _captureImage();
    });
  }

  void _stopTimeLapse() {
    captureTimer?.cancel();
    setState(() {
      _isRecording = false;
    });
    if (capturedVideosPath.isNotEmpty) {
      _showGenerateVideoDialog();
    }
  }

  Future<void> _captureImage() async {
    try {
      await initializeControllerFuture;
      final directory = await getApplicationDocumentsDirectory();
      // this is for the path which will be used to store the multiple images for timelapse
      final sessionDir = Directory(
        path.join(directory.path, 'timelapse_${timelapseType}_$sessionId'),
      );
      if (!await sessionDir.exists()) {
        await sessionDir.create(recursive: true);
      }
      //for sorting the captured images in the correct order
      final paddedCount = _imageCount.toString().padLeft(5, '0');
      final imagePath = path.join(sessionDir.path, 'frame_$paddedCount.jpg');
      final image = await cameraController.takePicture();
      // temporary holding the image path and used for copying like when we capture the image it needs some space where it would store the image if not stored the image the OS might delete some apps to clear up the space.
      await File(image.path).copy(imagePath);
      capturedVideosPath.add(imagePath);
      setState(() {
        _imageCount++;
      });
      print("Captured image $_imageCount at $imagePath");
    } catch (e) {
      print("Error capturing image: $e");
    }
  }

  void _showGenerateVideoDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("TimeLapse Complete"),
        content: Text('Captured $_imageCount images. Generate video now?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
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

  // now after capturing the video i have to compile all the images to form a timelapse
  Future<void> _generateVideo() async {
    if (capturedVideosPath.isEmpty) {
      return;
    }
    setState(() {
      _isProcessing = true;
    });
    try {
      final directory = await getApplicationDocumentsDirectory();
      final outputPath = path.join(
        directory.path,
        'timelapse_${timelapseType}_$sessionId.mp4',
      );
      final sessionDir = path.dirname(capturedVideosPath.first);
      final frameRate = _getFrameVideoRates();
      // now run the command to create videos from images
      final command =
          '-framerate $frameRate -pattern_type glob -i "$sessionDir/*.jpg" -c:v libx264 -pix_fmt yuv420p -y "$outputPath"';
      print('FFmpeg command:$command');
      await FFmpegKit.execute(command).then((session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          print("Video Generated Successfully at: $outputPath");
          setState(() {
            _generatedVideoPath = outputPath;
            _isProcessing = false;
          });
          _initializeVideoPlayer(outputPath);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Timelapse Video Created Successfully"),
              ),
            );
          }
        } else {
          final logs = await session.getOutput();
          print('FFmpeg failed with return code $returnCode');
          print('Logs: $logs');

          setState(() {
            _isProcessing = false;
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to generate video')),
            );
          }
        }
      });
    } catch (e) {
      print('Error generating video: $e');
      setState(() {
        _isProcessing = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _initializeVideoPlayer(String videoPath) async {
    videoPlayerController = VideoPlayerController.file(File(videoPath));
    await videoPlayerController!.initialize();
    setState(() {});
  }

  @override
  void dispose() {
    captureTimer?.cancel();
    cameraController.dispose();
    videoPlayerController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Timelapse - ${timelapseType.toUpperCase()}'),
        backgroundColor: Colors.deepPurple,
      ),
      body: FutureBuilder<void>(
        future: initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                Expanded(
                  child:
                      _generatedVideoPath != null &&
                          videoPlayerController != null
                      ? _buildVideoPreview()
                      : CameraPreview(cameraController),
                ),
                _buildControlPanel(),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }

  Widget _buildVideoPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: videoPlayerController!.value.aspectRatio,
            child: VideoPlayer(videoPlayerController!),
          ),
        ),
        Positioned(
          bottom: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
          if (_isProcessing)
            const Column(
              children: [
                CircularProgressIndicator(color: Colors.deepPurple),
                SizedBox(height: 10),
                Text(
                  'Generating video...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            )
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    const Text(
                      'Images Captured',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$_imageCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Column(
                  children: [
                    const Text(
                      'Interval',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_getCaptureTimingsIntervals().inMilliseconds / 1000}s',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Column(
                  children: [
                    const Text(
                      'Output FPS',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_getFrameVideoRates()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
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
                        disabledBackgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ElevatedButton.icon(
                      onPressed: _isRecording ? _stopTimeLapse : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        disabledBackgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
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
}
