import com.android.build.gradle.AppExtension
import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        maven { url = uri("file:///root/android-maven-seed") }
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// CI provisions a single NDK (the local-shell toolchain) and exposes it through
// ANDROID_NDK_HOME. Read its revision and pin every Android module to it so
// plugin defaults (27.0.12077973) and the app's pinned version do not require
// extra SDK downloads.
val ndkVersionFromEnv: String? =
    System.getenv("ANDROID_NDK_HOME")
        ?.let { java.io.File(it, "source.properties") }
        ?.takeIf { it.isFile }
        ?.let { file ->
            java.util.Properties()
                .apply { file.inputStream().use { load(it) } }
                .getProperty("Pkg.Revision")
        }

subprojects {
    afterEvaluate {
        val version = ndkVersionFromEnv
        if (!version.isNullOrEmpty()) {
            extensions.findByType(AppExtension::class.java)?.ndkVersion = version
            extensions.findByType(LibraryExtension::class.java)?.ndkVersion = version
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<LibraryExtension>("android") {
            defaultConfig {
                externalNativeBuild {
                    cmake {
                        arguments += "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=none"
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
