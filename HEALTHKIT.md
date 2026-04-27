# HealthKit Tool

Macrodex exposes Apple Health data to the on-device agent shell through the native `healthkit` command. It runs inside the app process, uses Macrodex's HealthKit permissions, and prints JSON.

## Permission Model

- The app asks for the default HealthKit read/write set once on launch.
- The user can request access again from Macrodex Settings > Health > Request HealthKit Access.
- From the shell, `healthkit request` opens the same system authorization prompt.
- iOS does not disclose read authorization status. If a query returns no rows, the data may be absent or read access may be denied.
- Write access can be checked with `healthkit status`.

## Command Summary

```sh
healthkit status
healthkit request
healthkit types
healthkit characteristics
healthkit query --type quantity --identifier stepCount --start today --end now
healthkit stats --identifier stepCount --start 2026-04-01 --end now --bucket day --stat sum
healthkit sync-nutrition --date today
healthkit write-quantity --identifier dietaryEnergyConsumed --value 450 --unit kcal --start now
healthkit write-category --identifier sleepAnalysis --value asleepCore --start 2026-04-22T23:00:00 --end 2026-04-23T07:00:00
healthkit write-workout --activity running --start 2026-04-23T07:00:00 --end 2026-04-23T07:30:00 --energy 250 --distance 5000
```

Use `healthkit help` for live CLI help. Use `--out /home/codex/file.json` instead of shell redirection when saving results.

## Dates

Date options accept:

- `now`, `today`, `yesterday`, `tomorrow`
- `YYYY-MM-DD`
- ISO-8601 timestamps such as `2026-04-23T07:30:00-04:00`
- epoch seconds or epoch milliseconds

`--date YYYY-MM-DD` is shorthand for the local day. For queries, omitted dates default to the last 7 days. For writes, `--start` is required and `--end` defaults to `--start`.

## Output Files

Shell redirection is not reliable for app-native commands. Use `--out` when you need a file:

```sh
healthkit stats --identifier stepCount --start today --end now --bucket hour --out /home/codex/steps-hourly.json
```

## Macrodex Nutrition Sync

Macrodex automatically attempts a best-effort sync for the selected nutrition day after the calorie dashboard refreshes. The agent can also invoke the same sync manually:

```sh
healthkit sync-nutrition --date today
healthkit sync-nutrition --days 7
healthkit sync-nutrition --start 2026-04-01 --end 2026-04-23
```

The command writes one daily aggregate HealthKit sample per supported nutrient with stable sync metadata, so reruns are idempotent. It syncs `calories_kcal`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugars_g`, `saturated_fat_g`, `cholesterol_mg`, `sodium_mg`, `potassium_mg`, `calcium_mg`, `iron_mg`, `vitamin_d_mcg`, and `caffeine_mg`.

HealthKit does not expose matching fields for `added_sugars_g` or `trans_fat_g`, so those are reported as unsupported. If HealthKit is unavailable or write access is missing for some nutrients, the command returns JSON with `ok: true` and `skipped` entries instead of hard failing.

## Quantities

Query samples:

```sh
healthkit query --type quantity --identifier heartRate --unit count/min --start today --limit 20
```

Bucket statistics:

```sh
healthkit stats --identifier activeEnergyBurned --unit kcal --start 2026-04-01 --end now --bucket day --stat sum
```

Write a quantity:

```sh
healthkit write-quantity --identifier bodyMass --value 82.4 --unit kg --start now --note "manual correction from Macrodex"
```

Quantities include activity, body, vital, and nutrition samples such as `stepCount`, `activeEnergyBurned`, `bodyMass`, `heartRate`, `oxygenSaturation`, `bloodGlucose`, `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryWater`, and `dietaryCaffeine`.

Run `healthkit types` for the full alias list. Raw `HKQuantityTypeIdentifier...` strings are accepted when HealthKit supports them.

## Categories

Query sleep:

```sh
healthkit query --type category --identifier sleepAnalysis --start yesterday --end today
```

Write sleep:

```sh
healthkit write-category --identifier sleepAnalysis --value asleepCore --start 2026-04-22T23:30:00 --end 2026-04-23T06:45:00
```

Categories include `sleepAnalysis`, `mindfulSession`, and `appleStandHour`. Sleep values include `inBed`, `asleep`, `asleepUnspecified`, `awake`, `asleepCore`, `asleepDeep`, and `asleepREM`. Raw integer category values are accepted for raw category identifiers.

## Workouts

Query workouts:

```sh
healthkit query --type workout --start 2026-04-01 --end now
```

Write a workout:

```sh
healthkit write-workout --activity cycling --start 2026-04-23T18:00:00 --end 2026-04-23T18:45:00 --energy 420 --distance 16000
```

Workouts support common activities such as `walking`, `running`, `cycling`, `hiking`, `swimming`, `yoga`, `hiit`, `strength`, `functionalStrength`, `mixedCardio`, `elliptical`, `rowing`, and `other`.

## Metadata And Idempotency

Writes accept optional metadata:

```sh
healthkit write-quantity --identifier dietaryCaffeine --value 95 --unit mg --start now --sync-id caffeine-2026-04-23-morning --sync-version 1 --metadata '{"source":"Macrodex Agent"}'
```

- `--sync-id` and `--sync-version` map to HealthKit sync metadata.
- `--note` writes `com.dj.Macrodex.note`.
- `--user-entered false` omits HealthKit's user-entered metadata flag.

## Agent Rules

- Ask for permission with `healthkit request` before telling the user HealthKit is unavailable.
- Use `healthkit sync-nutrition` after direct SQL changes to food logs when you need immediate HealthKit sync.
- Query before writing so you do not duplicate existing samples.
- Include explicit `--start`, `--end`, `--unit`, and `--note` on writes.
- Treat HealthKit writes as user health records. Do not write guessed data unless the user explicitly asks you to.
- Do not use shell redirects or pipelines with `healthkit`; use `--out`.
