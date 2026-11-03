package com.vitorpamplona.libbench

import java.util.Properties

/**
 * Resolved versions of every module on the runtime classpath, written at build time by
 * build.gradle.kts from the same resolution the lockfile pins (`group:module=version`).
 */
object Versions {
    private val props =
        Properties().apply {
            Versions::class.java.getResourceAsStream("/libbench-versions.properties")?.use { load(it) }
        }

    operator fun get(module: String): String = props.getProperty(module) ?: "unknown"
}
