export function greet(name?: string): string {
  return `hello, ${name && name.length > 0 ? name : "world"}`;
}
