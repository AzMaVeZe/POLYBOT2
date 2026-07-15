# 🎾 פאדלז׳יט — PadelJit

A score-keeping app for a 4-player padel Americano tournament. Hebrew (RTL) by default, with a one-tap English toggle.

## How it works

- **4 players** enter their names once, at the start of the tournament.
- Every game is played to a configurable total (default **32 points**) — the two teams' scores always add up to the target (e.g. 20–12), and typing one side fills in the other automatically.
- After every game the **players are shuffled** into new pairs. With 4 players there are 3 possible team combinations, and the app cycles through all of them in random order before reshuffling, so everyone partners with everyone.
- Each player collects the points their team scored in every game.
- The **ranking table** shows live standings: 1st, 2nd, 3rd and 4th place with each player's exact total points, games played and games won. Ties on points are broken by games won.
- A **game history** lists every game with the teams, winner and score — and every past game's score can be **edited** (✎) at any time; the standings recompute automatically.
- The state is saved in the browser (localStorage), so you can close the page and continue later on the same device.

## Running it

No build step, no server, no dependencies — it is a single HTML file.

Open `index.html` in any browser, or serve it locally:

```sh
python3 -m http.server 8000
# then open http://localhost:8000
```

Works well on a phone at the court, too.
