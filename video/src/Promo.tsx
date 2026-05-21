import { AbsoluteFill, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";

/**
 * Placeholder promo composition — Hark icon fades in, name + tagline rise
 * underneath. Swap in your real demo footage / dictation flow later.
 */
export const Promo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const iconScale = spring({ frame, fps, config: { damping: 20, stiffness: 110 } });
  const iconOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: "clamp" });

  const headlineY = interpolate(frame, [25, 55], [40, 0], { extrapolateRight: "clamp" });
  const headlineOpacity = interpolate(frame, [25, 55], [0, 1], { extrapolateRight: "clamp" });

  const taglineY = interpolate(frame, [50, 80], [30, 0], { extrapolateRight: "clamp" });
  const taglineOpacity = interpolate(frame, [50, 80], [0, 1], { extrapolateRight: "clamp" });

  return (
    <AbsoluteFill
      style={{
        background: "linear-gradient(180deg, #fafafa 0%, #f0f0f3 100%)",
        fontFamily:
          'system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif',
        color: "#0a0a0a",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 32,
      }}
    >
      {/* Static asset; <img> is fine here because the file is bundled at build
          time via staticFile() — Remotion's <Img> preloader isn't needed. */}
      <img
        src={staticFile("hark-icon.png")}
        alt="Hark"
        style={{
          width: 256,
          height: 256,
          borderRadius: 56,
          boxShadow: "0 20px 60px -20px rgba(0,0,0,0.25)",
          transform: `scale(${iconScale})`,
          opacity: iconOpacity,
        }}
      />
      <div
        style={{
          fontSize: 128,
          fontWeight: 600,
          letterSpacing: -3,
          transform: `translateY(${headlineY}px)`,
          opacity: headlineOpacity,
        }}
      >
        Hark
      </div>
      <div
        style={{
          fontSize: 40,
          color: "#52525b",
          transform: `translateY(${taglineY}px)`,
          opacity: taglineOpacity,
        }}
      >
        Voice control for macOS
      </div>
    </AbsoluteFill>
  );
};
