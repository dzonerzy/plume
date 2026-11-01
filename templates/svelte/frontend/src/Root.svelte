<script lang="ts">
  // Generated from src/app.zig at every build: App's methods, typed.
  import { App } from "./bindings";

  let name = $state("Plume");
  let answer = $state("");

  function greet(event: SubmitEvent) {
    event.preventDefault();
    // Synchronous: Zig runs in the same process, no await needed.
    answer = App.greet(name);
  }
</script>

<main class="min-h-screen grid place-items-center bg-slate-50 text-slate-900 dark:bg-slate-900 dark:text-slate-100">
  <div class="w-full max-w-md space-y-6 p-8 text-center">
    <h1 class="text-3xl font-semibold">{{title}}</h1>
    <p class="text-slate-500 dark:text-slate-400">A Plume app: Zig with a Svelte frontend.</p>
    <form onsubmit={greet} class="flex gap-2">
      <input
        bind:value={name}
        placeholder="Your name"
        class="flex-1 rounded-lg border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-800"
      />
      <button class="rounded-lg bg-sky-600 px-4 py-2 font-medium text-white hover:bg-sky-500">Greet</button>
    </form>
    <p class="min-h-6 font-medium">{answer}</p>
    <p class="text-sm text-slate-500 dark:text-slate-400">
      Edit <code>src/app.zig</code> and <code>frontend/src/Root.svelte</code>.
    </p>
  </div>
</main>
