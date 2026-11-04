pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "libbench"

// Benchmark an unreleased Quartz: point at a vitorpamplona/quartz checkout and its :quartz
// project replaces the Maven Central artifact (QUARTZ_DIR=… ./run.sh, or -PquartzDir=…). Its
// Quartz rows then record the checkout's commit instead of the release version.
providers.gradleProperty("quartzDir").orNull?.let { dir ->
    includeBuild(dir) {
        dependencySubstitution {
            substitute(module("com.vitorpamplona.quartz:quartz")).using(project(":quartz"))
        }
    }
}
