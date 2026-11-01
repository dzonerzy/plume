<script lang="ts">
  import { onMount } from "svelte";
  // Generated from src/app.zig at every build: App's methods and events, typed.
  import { App, Events, type Greeting } from "./bindings";
  import { duration, steps } from "./format";

  type Work = { state: "idle" } | { state: "running" } | { state: "finished"; took: string };

  let name = $state("");
  let greeting = $state<(Greeting & { took: string }) | null>(null);
  let done = $state(0);
  let work = $state<Work>({ state: "idle" });

  // Zig's "progress" events; the returned function stops listening.
  onMount(() => Events.on("progress", (progress) => (done = progress.done)));

  function greet(event: SubmitEvent) {
    event.preventDefault();
    const start = performance.now();
    // Synchronous: Zig runs in this process, no await needed.
    const answer = App.greet(name);
    greeting = { ...answer, took: duration(performance.now() - start) };
  }

  async function count() {
    done = 0;
    work = { state: "running" };
    const start = performance.now();
    try {
      await App.countTo(steps);
      work = { state: "finished", took: duration(performance.now() - start) };
    } catch {
      work = { state: "idle" };
    }
  }
</script>

<main class="shell">
  <header class="masthead">
    <span class="mark" aria-hidden="true"></span>
    <div>
      <h1 class="title">{{title}}</h1>
      <p class="lede">This window is Svelte; the work behind it is Zig, in the same process.</p>
    </div>
  </header>

  <section class="greet">
    <form class="ask" onsubmit={greet}>
      <label for="name" class="sr-only">Your name</label>
      <input id="name" class="field" placeholder="Your name" autocomplete="off" bind:value={name} />
      <button class="action">Greet</button>
    </form>
    {#if greeting}
      {#key greeting.number}
        <p class="answer" data-written aria-live="polite">{greeting.text}</p>
      {/key}
    {:else}
      <p class="answer" data-empty>Say hello to Zig.</p>
    {/if}
    <p class="trace">
      {#if greeting}Answered by Zig in <span class="code">{greeting.took}</span> (greeting {greeting.number}).{/if}
    </p>
  </section>

  <section class="work">
    <h2>Work on another thread</h2>
    <button class="action action-quiet" onclick={count} disabled={work.state === "running"}>
      {work.state === "finished" ? "Count again" : "Start"}
    </button>
    <div class="barbs" role="progressbar" aria-label="Progress" aria-valuemin={0} aria-valuemax={steps} aria-valuenow={done}>
      {#each { length: steps }, i}
        <span class="barb" data-on={i < done ? "" : undefined}></span>
      {/each}
    </div>
    <p class="trace">
      {#if work.state === "idle"}
        Start, and Zig counts to {steps} on a worker thread, sending an event at each step.
      {:else if work.state === "running"}
        Counted {done} of {steps}.
      {:else}
        Counted to {steps} in {work.took}, one event per step.
      {/if}
    </p>
  </section>

  <footer class="files">
    Edit <code>src/app.zig</code> for the Zig side and <code>frontend/src/Root.svelte</code> for this window.
    Under <code>plume dev</code>, both reload as you save.
  </footer>
</main>
