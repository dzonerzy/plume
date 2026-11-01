import "./style.css";
// Generated from src/app.zig at every build: App's methods and events, typed.
import { App, Events } from "./bindings";
import { duration, steps } from "./format";

document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <main class="shell">
    <header class="masthead">
      <span class="mark" aria-hidden="true"></span>
      <div>
        <h1 class="title">{{title}}</h1>
        <p class="lede">This window is plain TypeScript; the work behind it is Zig, in the same process.</p>
      </div>
    </header>

    <section class="greet">
      <form id="ask" class="ask">
        <label for="name" class="sr-only">Your name</label>
        <input id="name" class="field" placeholder="Your name" autocomplete="off" />
        <button class="action">Greet</button>
      </form>
      <p id="answer" class="answer" data-empty aria-live="polite">Say hello to Zig.</p>
      <p id="greet-trace" class="trace"></p>
    </section>

    <section class="work">
      <h2>Work on another thread</h2>
      <button id="count" class="action action-quiet">Start</button>
      <div id="barbs" class="barbs" role="progressbar" aria-label="Progress" aria-valuemin="0" aria-valuemax="${steps}" aria-valuenow="0">
        ${'<span class="barb"></span>'.repeat(steps)}
      </div>
      <p id="work-trace" class="trace">
        Start, and Zig counts to ${steps} on a worker thread, sending an event at each step.
      </p>
    </section>

    <footer class="files">
      Edit <code>src/app.zig</code> for the Zig side and <code>frontend/src/main.ts</code> for this window.
      Under <code>plume dev</code>, both reload as you save.
    </footer>
  </main>
`;

const element = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const answer = element<HTMLParagraphElement>("answer");
const countButton = element<HTMLButtonElement>("count");
const barbs = element<HTMLDivElement>("barbs");
const workTrace = element<HTMLParagraphElement>("work-trace");
let done = 0;

element<HTMLFormElement>("ask").addEventListener("submit", (event) => {
  event.preventDefault();
  const start = performance.now();
  // Synchronous: Zig runs in this process, no await needed.
  const greeting = App.greet(element<HTMLInputElement>("name").value);
  const took = duration(performance.now() - start);

  answer.textContent = greeting.text;
  answer.removeAttribute("data-empty");
  // Written again: the animation restarts.
  answer.removeAttribute("data-written");
  void answer.offsetWidth;
  answer.setAttribute("data-written", "");
  element("greet-trace").innerHTML = `Answered by Zig in <span class="code">${took}</span> (greeting ${greeting.number}).`;
});

function showProgress(count: number) {
  done = count;
  barbs.setAttribute("aria-valuenow", String(count));
  barbs.querySelectorAll(".barb").forEach((barb, i) => barb.toggleAttribute("data-on", i < count));
  if (countButton.disabled) workTrace.textContent = `Counted ${count} of ${steps}.`;
}

// Zig's "progress" events, sent from its worker thread.
Events.on("progress", (progress) => showProgress(progress.done));

countButton.addEventListener("click", async () => {
  countButton.disabled = true;
  showProgress(0);
  const start = performance.now();
  try {
    await App.countTo(steps);
    workTrace.textContent = `Counted to ${steps} in ${duration(performance.now() - start)}, one event per step.`;
    countButton.textContent = "Count again";
  } catch {
    workTrace.textContent = `Counting stopped at ${done} of ${steps}.`;
  } finally {
    countButton.disabled = false;
  }
});
