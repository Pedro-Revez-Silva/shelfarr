# kotlinx.serialization ships its own consumer rules; Readium and Media3 do too.
# Keep the JSON models' generated serializers reachable by name.
-keepclassmembers class org.shelfarr.app.core.** {
    *** Companion;
}
-keepclasseswithmembers class org.shelfarr.app.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}
