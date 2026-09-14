import {TerminalActionRail} from "./TerminalActionRail";
import {TerminalDriftChart} from "./TerminalDriftChart";
import {TerminalHeader} from "./TerminalHeader";
import {TerminalPoolRail} from "./TerminalPoolRail";
import {TerminalSwapsTable} from "./TerminalSwapsTable";
import {TerminalTicker} from "./TerminalTicker";
import {TerminalTour} from "./TerminalTour";

/**
 * Trade-terminal layout: three columns above a live ticker strip.
 *   ┌─────────────┬───────────────────────────────────────┬─────────────────┐
 *   │  PoolRail   │  Header · DriftChart · SwapsTable     │  Action rail    │
 *   └─────────────┴───────────────────────────────────────┴─────────────────┘
 *   │                      TerminalTicker                                   │
 *   └───────────────────────────────────────────────────────────────────────┘
 * Fills the viewport under the site Header. Rails don't scroll the page - the
 * center column owns page scroll if needed.
 */
export function TerminalShell() {
  return (
    <div className="flex h-[calc(100vh-56px)] min-h-[760px] flex-col bg-bg">
      <div className="grid flex-1 min-h-0 grid-cols-[minmax(280px,320px)_minmax(0,1fr)_minmax(440px,480px)]">
        <TerminalPoolRail />
        <div className="flex min-w-0 flex-col overflow-hidden">
          <TerminalHeader />
          <div className="flex-1 min-h-0 overflow-y-auto">
            <TerminalDriftChart />
            <TerminalSwapsTable />
          </div>
        </div>
        <TerminalActionRail />
      </div>
      <TerminalTicker />
      <TerminalTour />
    </div>
  );
}
