allprojects {
    repositories {
        google()
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
subprojects {
    project.evaluationDependsOn(":app")
}

// tflite_flutter's own Android module declares Java 11 for its Java sources
// (android/build.gradle inside the package), but its Kotlin compile task
// inherits 17 from somewhere else in this build's ambient toolchain — Gradle
// refuses to build a module whose own Java and Kotlin tasks disagree
// ("Inconsistent JVM-target compatibility"). Forcing every subproject up to
// 17 (tried first) breaks OTHER modules (e.g. `:jni`) that finalize their own
// compileOptions earlier in AGP's lifecycle than a project-wide override can
// reach safely. Targeting only this one module's Kotlin task — to match what
// it already declares for Java, rather than the other way around — fixes the
// mismatch without touching any other module's configuration at all.
project(":tflite_flutter") {
    afterEvaluate {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
