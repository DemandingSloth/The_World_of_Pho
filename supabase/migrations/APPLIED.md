# Applied migrations

Record of which migrations have been run in the Supabase SQL editor.
Update this file whenever a new migration is run.

| Migration | Status | Notes |
|---|---|---|
| 001–103 | ✅ Run | 103 (guild sales) run with the revised price floor: score × 1,000 / 5,000 / 10,000 by total upgrade levels (≤5 / 6–10 / 11+). |
| 104 | ✅ Run | Trader's Tongue: server-side mission boost window + claim_mission doubling. |
| 105 | ✅ Run | Restore account to this device with a recovery code (restore_account_to_device). |
| 106 | ✅ Run | Sell guild to the game (Guild Exchange): paid at floor, re-listed at floor + 5%, max 3 held. |
| 107 | ✅ Run | Horse prestige: Master Trainer (training cap 11→50) + Bigger Barn (+1→+10 stable slots). |
| 108 | ✅ Run | Horse market: listed horses can't be paddocked; buyers don't see unbuyable listings. |
| 109 | ✅ Run | My Bets: get_my_bets returns placed_at, race_name, resolved_at. |
| 110 | ✅ Run | get_server_time — anchor for the TrustedClock anti clock-change system. |

Next new migration number: **111**.
