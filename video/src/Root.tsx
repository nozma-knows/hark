import { Composition } from "remotion";
import { Promo } from "./Promo";

// 1080p @ 30fps, 8-second loop suitable for landing-page hero and social.
const FPS = 30;
const DURATION_SECONDS = 8;

export const Root: React.FC = () => {
  return (
    <>
      <Composition
        id="Promo"
        component={Promo}
        durationInFrames={FPS * DURATION_SECONDS}
        fps={FPS}
        width={1920}
        height={1080}
      />
    </>
  );
};
