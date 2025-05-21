allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    project.afterEvaluate {
        if (project.plugins.hasPlugin("java") || project.plugins.hasPlugin("java-library")) {
            project.extensions.findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)?.apply {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }
        }
        // Safely configure the "kotlinOptions" extension if it exists
        (project.extensions.findByName("kotlinOptions") as? org.jetbrains.kotlin.gradle.dsl.KotlinJvmOptions)?.apply {
            jvmTarget = JavaVersion.VERSION_11.toString()
        }
        project.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }
            // For Kotlin in Android subprojects, configure kotlinOptions if present
            (this as? org.gradle.api.plugins.ExtensionAware)?.extensions?.findByName("kotlinOptions")?.let {
                (this as org.gradle.api.plugins.ExtensionAware).extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmOptions>("kotlinOptions") {
                    jvmTarget = JavaVersion.VERSION_11.toString()
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
