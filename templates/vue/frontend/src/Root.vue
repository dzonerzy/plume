<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
// Generated from src/app.zig at every build: App's methods and events, typed.
import { App, Events, type Greeting } from "./bindings";
import { duration, steps } from "./format";

type Work = { state: "idle" } | { state: "running" } | { state: "finished"; took: string };

const name = ref("");
const greeting = ref<(Greeting & { took: string }) | null>(null);
const done = ref(0);
const work = ref<Work>({ state: "idle" });

// Zig's "progress" events; the returned function stops listening.
let stop = () => {};
onMounted(() => (stop = Events.on("progress", (progress) => (done.value = progress.done))));
onUnmounted(() => stop());

function greet() {
  const start = performance.now();
  // Synchronous: Zig runs in this process, no await needed.
  const answer = App.greet(name.value);
  greeting.value = { ...answer, took: duration(performance.now() - start) };
}

async function count() {
  done.value = 0;
  work.value = { state: "running" };
  const start = performance.now();
  try {
    await App.countTo(steps);
    work.value = { state: "finished", took: duration(performance.now() - start) };
  } catch {
    work.value = { state: "idle" };
  }
}
</script>

<template>
  <main class="shell">
    <header class="masthead">
      <span class="mark" aria-hidden="true"></span>
      <div>
        <h1 class="title">{{title}}</h1>
        <p class="lede">This window is Vue; the work behind it is Zig, in the same process.</p>
      </div>
    </header>

    <section class="greet">
      <form class="ask" @submit.prevent="greet">
        <label for="name" class="sr-only">Your name</label>
        <input id="name" v-model="name" class="field" placeholder="Your name" autocomplete="off" />
        <button class="action">Greet</button>
      </form>
      <p v-if="greeting" :key="greeting.number" class="answer" data-written aria-live="polite">{{ greeting.text }}</p>
      <p v-else class="answer" data-empty>Say hello to Zig.</p>
      <p class="trace">
        <template v-if="greeting">
          Answered by Zig in <span class="code">{{ greeting.took }}</span> (greeting {{ greeting.number }}).
        </template>
      </p>
    </section>

    <section class="work">
      <h2>Work on another thread</h2>
      <button class="action action-quiet" :disabled="work.state === 'running'" @click="count">
        {{ work.state === "finished" ? "Count again" : "Start" }}
      </button>
      <div class="barbs" role="progressbar" aria-label="Progress" aria-valuemin="0" :aria-valuemax="steps" :aria-valuenow="done">
        <span v-for="i in steps" :key="i" class="barb" :data-on="i <= done ? '' : undefined"></span>
      </div>
      <p class="trace">
        <template v-if="work.state === 'idle'">
          Start, and Zig counts to {{ steps }} on a worker thread, sending an event at each step.
        </template>
        <template v-else-if="work.state === 'running'">Counted {{ done }} of {{ steps }}.</template>
        <template v-else>Counted to {{ steps }} in {{ work.took }}, one event per step.</template>
      </p>
    </section>

    <footer class="files">
      Edit <code>src/app.zig</code> for the Zig side and <code>frontend/src/Root.vue</code> for this window.
      Under <code>plume dev</code>, both reload as you save.
    </footer>
  </main>
</template>
