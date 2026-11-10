# Image processing command-line interface

The app build embeds `Me2Comic.app/Contents/MacOS/me2comic-cli`. Build/archive the Me2Comic scheme to include it. GUI and CLI share ImageProcessingRunner, task organization and GraphicsMagick processing.

```sh
me2comic-cli --version
me2comic-cli settings
me2comic-cli process --request request.json
```

The settings command prints a read-only snapshot of the app's settings and output directory, with the same effective parameters used by the GUI. Pass that snapshot unchanged to processing requests.

```json
{
  "settings": {
    "outputDirectory": "/path/to/output",
    "parameters": {
      "widthThreshold": 3000,
      "resizeHeight": 1648,
      "quality": 92,
      "threadCount": 0,
      "batchSize": 40,
      "unsharpRadius": 0,
      "unsharpSigma": 0,
      "unsharpAmount": 0,
      "unsharpThreshold": 0,
      "useGrayColorspace": false
    }
  },
  "jobs": [
    {"id": "B001", "input": "/path/to/input/B001", "output": "/path/to/processed"},
    {"id": "B002", "input": "/path/to/input/B002", "output": "/path/to/processed"}
  ]
}
```

Each input is one directory containing images directly. Output is a **parent directory**: this example writes to processed/B001/ and processed/B002/. Use unique IDs and distinct resulting directories. Jobs sharing an output root run together in the existing image worker pool.

Input images are preserved. Use fresh working directories; existing files follow the GUI's collision naming rules, and results list newly generated images only. A retry may clear only the caller's own incomplete output directory. Results check generated image counts and readable dimensions.

Standard output uses newline-delimited JSON: `job_started`, `job_result`, and a final `summary` with `results` in request order. Job results contain `id`, `status` (`succeeded`, `failed`, `cancelled`), `outputs`, and an optional `error`. Request/startup errors use an `error` event. Detailed diagnostics go to standard error.

Exit codes: 0 = all jobs succeeded; 1 = processing failed; 2 = invalid request/settings; 130 = cancelled. SIGINT/SIGTERM cancel owned child processes and finish the result report. Saved app preferences are read without modification; no windows are opened.

The version command reports the existing painter build name when the app has no numeric build.
