package com.vitorpamplona.libbench

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** Plain Kotlin values (maps, lists, strings, numbers, booleans, null) to and from JSON text. */
object Js {
    private val pretty = Json { prettyPrint = true }

    fun toElement(v: Any?): JsonElement =
        when (v) {
            null -> JsonNull
            is JsonElement -> v
            is String -> JsonPrimitive(v)
            is Boolean -> JsonPrimitive(v)
            is Int -> JsonPrimitive(v)
            is Long -> JsonPrimitive(v)
            is Double -> if (v.isNaN() || v.isInfinite()) JsonNull else JsonPrimitive(v)
            is Number -> JsonPrimitive(v)
            is Map<*, *> -> JsonObject(v.entries.associate { (k, x) -> k.toString() to toElement(x) })
            is Iterable<*> -> JsonArray(v.map { toElement(it) })
            is LongArray -> JsonArray(v.map { JsonPrimitive(it) })
            else -> JsonPrimitive(v.toString())
        }

    fun write(
        v: Any?,
        prettyPrint: Boolean = false,
    ): String = (if (prettyPrint) pretty else Json).encodeToString(JsonElement.serializer(), toElement(v))

    fun parse(text: String): Any? = fromElement(Json.parseToJsonElement(text))

    fun fromElement(e: JsonElement): Any? =
        when (e) {
            JsonNull -> null
            is JsonObject -> LinkedHashMap<String, Any?>().apply { e.forEach { (k, v) -> put(k, fromElement(v)) } }
            is JsonArray -> e.map { fromElement(it) }
            is JsonPrimitive ->
                when {
                    e.isString -> e.content
                    e.booleanOrNull != null -> e.booleanOrNull
                    e.longOrNull != null -> e.longOrNull
                    else -> e.doubleOrNull
                }
        }
}
