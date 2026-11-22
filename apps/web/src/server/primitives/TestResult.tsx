export type TestOutcome = { tone: "success" | "error"; message: string; at: Date; note?: string | undefined };

export function TestResult({ result }: { result: TestOutcome | null }) {
  if (!result) return null;
  const time = result.at.toLocaleTimeString("en", { hour: "2-digit", minute: "2-digit" });
  return (
    <p className={`test-result test-result--${result.tone}`}>
      <span aria-hidden="true">{result.tone === "success" ? "✓ " : "⚠ "}</span>
      {result.message} <time dateTime={result.at.toISOString()}>{time}</time>
      {result.note ? <span className="test-result-note"> {result.note}</span> : null}
    </p>
  );
}
