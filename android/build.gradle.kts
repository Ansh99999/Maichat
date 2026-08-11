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

// file_picker 11.x skips applying the Kotlin plugin on AGP 9+, expecting AGP's
// built-in Kotlin — but its library module never gets it, so its Kotlin
// sources (FilePickerPlugin) don't compile. Supply the plugin ourselves.
subprojects {
    if (name == "file_picker" || name == "url_launcher_android") {
        plugins.apply("org.jetbrains.kotlin.android")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
