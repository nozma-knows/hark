import { Config } from "@remotion/cli/config";

// Render hardware acceleration is preferred but falls back to CPU automatically.
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
Config.setEntryPoint("src/index.ts");
