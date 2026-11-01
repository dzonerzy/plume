import { mount } from "svelte";
import "./style.css";
import Root from "./Root.svelte";

export default mount(Root, { target: document.getElementById("app")! });
