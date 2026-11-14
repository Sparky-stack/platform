import { greet } from "../lib/greet.ts";

export default function Home() {
  return <main>{greet()}</main>;
}
