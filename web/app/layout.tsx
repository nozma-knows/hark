import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://tellhark.com"),
  title: "Hark — Voice control for macOS",
  description:
    "Hold Fn, speak, release. Hark turns your voice into text, paste, or commands on macOS. On-device transcription, bring your own Claude.",
  openGraph: {
    title: "Hark — Voice control for macOS",
    description:
      "Hold Fn, speak, release. Voice → text, paste, or commands on macOS.",
    url: "https://tellhark.com",
    siteName: "Hark",
    images: [{ url: "/hark-icon.png", width: 1024, height: 1024 }],
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Hark — Voice control for macOS",
    description:
      "Hold Fn, speak, release. Voice → text, paste, or commands on macOS.",
    images: ["/hark-icon.png"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-white text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
        {children}
      </body>
    </html>
  );
}
