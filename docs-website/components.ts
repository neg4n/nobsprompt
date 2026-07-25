import { defineComponents } from "blume";
import Logo from "./components/Logo.astro";
import OptimizedVideo from "./components/OptimizedVideo.astro";
import Header from "./components/blume/Header.astro";

export default defineComponents({
  mdx: {
    OptimizedVideo,
  },
  layout: {
    Header,
    Logo,
  },
});
