import Image from "next/image";

const DOWNLOAD_URL = "https://tellhark.com/latest.dmg";
const GITHUB_URL = "https://github.com/nozma-knows/hark";
const VERSION = "v0.1.0";

export default function Home() {
  return (
    <main className="flex-1 flex flex-col items-center px-6 sm:px-8">
      <Hero />
      <Features />
      <HowItWorks />
      <Install />
      <Footer />
    </main>
  );
}

function Hero() {
  return (
    <section className="w-full max-w-3xl pt-24 sm:pt-32 pb-20 flex flex-col items-center text-center">
      <Image
        src="/hark-icon.png"
        alt="Hark"
        width={128}
        height={128}
        priority
        className="rounded-3xl shadow-[0_8px_30px_-12px_rgba(0,0,0,0.18)] dark:shadow-[0_8px_30px_-12px_rgba(255,255,255,0.06)]"
      />
      <h1 className="mt-8 text-5xl sm:text-6xl font-semibold tracking-tight">
        Hark
      </h1>
      <p className="mt-4 text-xl sm:text-2xl text-zinc-600 dark:text-zinc-400">
        Voice control for macOS.
      </p>
      <p className="mt-3 max-w-xl text-base sm:text-lg text-zinc-500 dark:text-zinc-500">
        Hold <Kbd>Fn</Kbd>, speak, release. Hark turns your voice into text,
        paste, or commands — on-device, anywhere on your Mac.
      </p>

      <div className="mt-10 flex flex-col sm:flex-row items-center gap-3">
        <a
          href={DOWNLOAD_URL}
          className="inline-flex items-center justify-center rounded-full bg-zinc-900 text-white px-7 py-3.5 text-base font-medium hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200 transition"
        >
          Download for macOS
        </a>
        <a
          href={GITHUB_URL}
          className="inline-flex items-center justify-center rounded-full border border-zinc-200 dark:border-zinc-800 px-7 py-3.5 text-base font-medium hover:bg-zinc-50 dark:hover:bg-zinc-900 transition"
        >
          GitHub
        </a>
      </div>

      <p className="mt-6 text-sm text-zinc-500">
        {VERSION} · Apple Silicon · macOS 14+
      </p>
    </section>
  );
}

function Features() {
  const items = [
    {
      shortcut: <Kbd>Fn</Kbd>,
      title: "Dictate",
      body: "Push-to-talk transcription. Hold Fn, speak, release — the transcript appears in the pill at the bottom of your screen.",
    },
    {
      shortcut: (
        <>
          <Kbd>⌃</Kbd>
          <span className="mx-1 text-zinc-400">+</span>
          <Kbd>Fn</Kbd>
        </>
      ),
      title: "Paste",
      body: "Polishes the raw transcript and pastes it wherever your cursor is — Slack, your editor, the browser address bar, anywhere.",
    },
    {
      shortcut: (
        <>
          <Kbd>⇧</Kbd>
          <span className="mx-1 text-zinc-400">+</span>
          <Kbd>Fn</Kbd>
        </>
      ),
      title: "Command",
      body: '"Open Linear in my work profile." "Take a screenshot." "Play music." Voice commands run through the Claude Agent SDK.',
    },
  ];

  return (
    <section className="w-full max-w-3xl py-16 border-t border-zinc-100 dark:border-zinc-900">
      <h2 className="text-2xl font-semibold mb-10">What it does</h2>
      <div className="space-y-8">
        {items.map((item) => (
          <div
            key={item.title}
            className="flex flex-col sm:flex-row sm:items-baseline gap-3 sm:gap-8"
          >
            <div className="sm:w-32 flex-shrink-0 flex items-center gap-1">
              {item.shortcut}
            </div>
            <div className="flex-1">
              <h3 className="text-lg font-medium">{item.title}</h3>
              <p className="mt-1 text-zinc-600 dark:text-zinc-400">
                {item.body}
              </p>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function HowItWorks() {
  return (
    <section className="w-full max-w-3xl py-16 border-t border-zinc-100 dark:border-zinc-900">
      <h2 className="text-2xl font-semibold mb-6">How it works</h2>
      <div className="space-y-5 text-zinc-600 dark:text-zinc-400 text-base leading-relaxed">
        <p>
          Transcription runs on-device via{" "}
          <a
            href="https://github.com/argmaxinc/WhisperKit"
            className="underline decoration-zinc-300 dark:decoration-zinc-700 hover:decoration-zinc-900 dark:hover:decoration-zinc-100"
          >
            WhisperKit
          </a>{" "}
          on the Apple Neural Engine. Your audio never leaves your Mac.
        </p>
        <p>
          Claude cleans the raw Whisper output — punctuation, casing, removing
          fillers — without paraphrasing. Voice commands execute through the
          Claude Agent SDK with a tightly scoped Bash tool.
        </p>
        <p>
          Hark is <em>bring-your-own-Claude</em>: either a Claude Code
          subscription token (the same one the{" "}
          <code className="font-mono text-sm bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">
            claude
          </code>{" "}
          CLI uses) or an{" "}
          <code className="font-mono text-sm bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">
            ANTHROPIC_API_KEY
          </code>
          . We never bundle credentials.
        </p>
      </div>
    </section>
  );
}

function Install() {
  return (
    <section className="w-full max-w-3xl py-16 border-t border-zinc-100 dark:border-zinc-900">
      <h2 className="text-2xl font-semibold mb-6">Install</h2>
      <ol className="space-y-3 text-zinc-600 dark:text-zinc-400 list-decimal list-inside">
        <li>
          <a
            href={DOWNLOAD_URL}
            className="underline decoration-zinc-300 dark:decoration-zinc-700 hover:decoration-zinc-900 dark:hover:decoration-zinc-100"
          >
            Download the latest DMG
          </a>{" "}
          and drag{" "}
          <span className="font-medium text-zinc-900 dark:text-zinc-100">Hark</span>{" "}
          into Applications.
        </li>
        <li>
          On first launch, grant{" "}
          <span className="font-medium text-zinc-900 dark:text-zinc-100">
            Microphone
          </span>{" "}
          and{" "}
          <span className="font-medium text-zinc-900 dark:text-zinc-100">
            Accessibility
          </span>{" "}
          permissions when prompted.
        </li>
        <li>
          Set up Claude in the Settings tab — either run{" "}
          <code className="font-mono text-sm bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">
            claude setup-token
          </code>{" "}
          or paste an{" "}
          <code className="font-mono text-sm bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">
            ANTHROPIC_API_KEY
          </code>
          .
        </li>
      </ol>
    </section>
  );
}

function Footer() {
  return (
    <footer className="w-full max-w-3xl py-12 border-t border-zinc-100 dark:border-zinc-900 mt-8">
      <div className="flex flex-col sm:flex-row justify-between items-center gap-4 text-sm text-zinc-500">
        <span>© {new Date().getFullYear()} Noah Milberger</span>
        <div className="flex items-center gap-6">
          <a
            href={GITHUB_URL}
            className="hover:text-zinc-900 dark:hover:text-zinc-100 transition"
          >
            GitHub
          </a>
          <a
            href={DOWNLOAD_URL}
            className="hover:text-zinc-900 dark:hover:text-zinc-100 transition"
          >
            Download
          </a>
        </div>
      </div>
    </footer>
  );
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center justify-center min-w-[2rem] h-7 px-1.5 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 font-mono text-sm shadow-sm">
      {children}
    </kbd>
  );
}
