package com.example.untitled2

import io.flutter.embedding.android.FlutterFragmentActivity

// `local_auth` (used for the biometric gate on verified documents)
// requires the host Activity to be a `FragmentActivity`. Flutter's
// default `FlutterActivity` doesn't satisfy that — it extends
// `androidx.appcompat.app.AppCompatActivity` but not `FragmentActivity`
// in a way the plugin recognises. `FlutterFragmentActivity` does, and
// is otherwise behaviourally identical for our purposes.
class MainActivity : FlutterFragmentActivity()
