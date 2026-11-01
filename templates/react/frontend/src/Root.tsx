import { useState, type FormEvent } from "react";
// Generated from src/app.zig at every build: App's methods, typed.
import { App } from "./bindings";

export default function Root() {
  const [name, setName] = useState("Plume");
  const [answer, setAnswer] = useState("");

  function greet(event: FormEvent) {
    event.preventDefault();
    // Synchronous: Zig runs in the same process, no await needed.
    setAnswer(App.greet(name));
  }

  return (
    <main className="min-h-screen grid place-items-center bg-slate-50 text-slate-900 dark:bg-slate-900 dark:text-slate-100">
      <div className="w-full max-w-md space-y-6 p-8 text-center">
        <h1 className="text-3xl font-semibold">{"{{title}}"}</h1>
        <p className="text-slate-500 dark:text-slate-400">A Plume app: Zig with a React frontend.</p>
        <form onSubmit={greet} className="flex gap-2">
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="Your name"
            className="flex-1 rounded-lg border border-slate-300 bg-white px-3 py-2 dark:border-slate-700 dark:bg-slate-800"
          />
          <button className="rounded-lg bg-sky-600 px-4 py-2 font-medium text-white hover:bg-sky-500">Greet</button>
        </form>
        <p className="min-h-6 font-medium">{answer}</p>
        <p className="text-sm text-slate-500 dark:text-slate-400">
          Edit <code>src/app.zig</code> and <code>frontend/src/Root.tsx</code>.
        </p>
      </div>
    </main>
  );
}
