# Android RTL Layout Lock Fix

This package did not contain native Android source files such as:

- AndroidManifest.xml
- res/layout/*
- Kotlin/Java Activity files
- Gradle Android module structure

Because of that, the RTL fix could not be applied directly to source code automatically.

To permanently force the UI to stay LTR while still supporting Arabic text rendering:

## AndroidManifest.xml

Add:

```xml
<application
    android:supportsRtl="false">
</application>
```

## Force Layout Direction in Base Activity

```kotlin
window.decorView.layoutDirection = View.LAYOUT_DIRECTION_LTR
```

## Arabic TextViews

```xml
android:textDirection="locale"
```

## Avoid RTL-aware attributes

Avoid:
- start/end
- marginStart
- paddingStart
- constraintStart

Use:
- left/right
- marginLeft
- paddingLeft
- constraintLeft

## BottomNavigationView

```xml
android:layoutDirection="ltr"
```

## RecyclerView

```kotlin
recyclerView.layoutDirection = View.LAYOUT_DIRECTION_LTR
```

## FAB

Use:
```xml
android:layout_gravity="bottom|right"
```

instead of:
```xml
bottom|end
```
