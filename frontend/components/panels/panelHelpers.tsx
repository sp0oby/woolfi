import {parseUnits} from "viem";

export function ModeTabs<Mode extends string>({
  mode,
  modes,
  setMode,
}: {
  mode: Mode;
  modes: readonly {id: Mode; label: string}[];
  setMode: (mode: Mode) => void;
}) {
  return (
    <div className="flex items-baseline gap-4 font-mono text-[11px] uppercase tracking-[0.22em]">
      {modes.map((item, index) => (
        <span key={item.id} className="flex items-baseline gap-4">
          {index > 0 ? (
            <span aria-hidden className="text-line">
              ·
            </span>
          ) : null}
          <button
            type="button"
            onClick={() => setMode(item.id)}
            className={`transition-colors ${
              item.id === mode ? "text-white" : "text-muted hover:text-ink"
            }`}
          >
            {item.label}
          </button>
        </span>
      ))}
    </div>
  );
}

export function parseAmount(value: string, decimals: number): bigint | undefined {
  if (!value || value === "." || value.startsWith(".")) return undefined;
  const [, fraction = ""] = value.split(".");
  if (!/^\d+(?:\.\d*)?$/.test(value) || fraction.length > decimals) return undefined;
  try {
    return parseUnits(value as `${number}`, decimals);
  } catch {
    return undefined;
  }
}

export function btnCls(disabled: boolean) {
  return `block w-full py-3 border border-line font-mono text-[11px] uppercase tracking-[0.22em] transition-colors ${
    disabled ? "text-muted cursor-not-allowed" : "text-white hover:bg-white/5"
  }`;
}
