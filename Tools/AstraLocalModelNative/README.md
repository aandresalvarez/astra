# ASTRA Native Local Model Helper

This package is intentionally separate from the root ASTRA SwiftPM package.
It is the MLX build of `astra-local-model`, so normal ASTRA tests do not
resolve or compile MLX, Metal, Hugging Face, or tokenizer dependencies.

Build it directly when validating local inference:

```bash
swift build --package-path Tools/AstraLocalModelNative --product astra-local-model-native
```

The app build bundles this native helper by default:

```bash
./script/build_and_run.sh --verify
```

Use the scaffold backend only for explicit lightweight developer builds:

```bash
ASTRA_LOCAL_MODEL_BACKEND=scaffold ./script/build_and_run.sh --verify
```

ASTRA owns the user-facing setup path. Runtime settings downloads supported MLX
model artifacts into the app's `LocalModels` folder, validates the selected
folder, and then launches this helper for readiness checks or inference. Manual
folder selection remains an advanced import path for already-downloaded MLX
models.
