# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Pigeon
-keep class dev.flutter.pigeon.** { *; }
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }

# Keep your own classes
-keep class com.example.timelapse_app.** { *; }

# FFmpegKit - Comprehensive Rules
-keep class com.arthenica.** { *; }
-keep class com.antonkarpenko.** { *; }
-keep class com.video_trimmer.** { *; }
-keepclassmembers class com.arthenica.** { *; }
-keepclassmembers class com.antonkarpenko.** { *; }

# Native Methods (JNI)
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep all native methods
-keepclasseswithmembers class * {
    native <methods>;
}

# Essential Attributes for JSON/Reflection/Pigeon
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes Exceptions

# Prevent obfuscation of classes with native methods
-keepnames class * {
    native <methods>;
}

# Keep enum classes
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Serializable classes
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Play Core
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
