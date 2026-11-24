// Text that looks like a comment is JSX text, and is listed once as text.
const a = <p> /* text, not a comment */ hello // also text
</p>;
const b = <i>{value} /* after a container */</i>;
const c = /=\/*/.test(s); /* a real comment */
