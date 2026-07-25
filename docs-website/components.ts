import { defineComponents } from "blume";
import Logo from "./components/Logo.astro";
import OptimizedVideo from "./components/OptimizedVideo.astro";

export default defineComponents({
  mdx: {
    OptimizedVideo,
  },
  layout: {
    Logo,
  },
});
