# Flutter Wrapper Proguard rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep App custom native bridging classes
-keep class com.maibot.maibot_android.** { *; }

# Ignore missing Play Core classes referenced by Flutter's deferred components
-dontwarn com.google.android.play.core.**

# MCP Kotlin SDK, Ktor CIO, and kotlinx.serialization
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-keep class io.modelcontextprotocol.** { *; }
-keep class io.ktor.** { *; }
-keep class kotlinx.serialization.** { *; }
-dontwarn io.ktor.**
-dontwarn io.modelcontextprotocol.**
-dontwarn kotlinx.serialization.**
-dontwarn org.slf4j.**
-dontwarn java.lang.management.**
-dontwarn javax.naming.**
-dontwarn java.nio.file.**
-dontwarn sun.misc.Unsafe
