import "./style.css";
// Generated from src/app.zig at every build: App's methods, typed.
import { App } from "./bindings";

document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <main class="min-h-screen grid place-items-center bg-slate-50 text-slate-900 dark:bg-slate-900 dark:text-slate-100">
    <div class="w-full max-w-md space-y-6 p-8 text-center">
      <h1 class="text-3xl font-semibold">{{title}}</h1>
      <p class="text-slate-500 dark:text-slate-400">A Plume app: Zig with a web frontend.</p>
      <form id="greet" class="flex gap-2">
        <input id="name" placeholder="Your name" value="Plume"
          class="flex-1 rounded-lg border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-800" />
        <button class="rounded-lg bg-sky-600 px-4 py-2 font-medium text-white hover:bg-sky-500">Greet</button>
      </form>
      <p id="answer" class="min-h-6 font-medium"></p>
      <p class="text-sm text-slate-500 dark:text-slate-400">
        Edit <code>src/app.zig</code> and <code>frontend/src/main.ts</code>.
      </p>
    </div>
  </main>
`;

document.querySelector<HTMLFormElement>("#greet")!.addEventListener("submit", (event) => {
  event.preventDefault();
  const name = document.querySelector<HTMLInputElement>("#name")!.value;
  // Synchronous: Zig runs in the same process, no await needed.
  document.querySelector("#answer")!.textContent = App.greet(name);
});
