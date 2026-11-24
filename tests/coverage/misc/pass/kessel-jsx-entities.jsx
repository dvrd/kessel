// Character references in JSX text and in string attributes are decoded into
// `value`; `raw` keeps the source. None of these forms is an error: what does
// not decode (unknown name, no semicolon, out-of-range number) stays literal.
const named = <a title="&amp;&lt;&gt;&quot;&apos;&nbsp;">&amp;&lt;&gt;&quot;&apos;&nbsp;&copy;</a>;
const decimal = <a title="&#65;&#8364;">&#65;&#8364;</a>;
const hex = <a title="&#x41;&#x1F600;">&#x41;&#x1F600;</a>;
const unknown = <a title="&foo;&AMP;">&foo;&AMP;</a>;
const unterminated = <a title="&amp x &lt">&amp x &lt</a>;
const out_of_range = <a title="&#1114112;&#x110000;&#xD800;">&#1114112;&#x110000;&#xD800;</a>;
const nested = <a title="&amp;lt;">&amp;lt;</a>;
const decoded_brackets = <a>&gt;&#62;&#125;</a>;
const in_expression = <a title={"&amp;"}>{"&amp;"}</a>;
