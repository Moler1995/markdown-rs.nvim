A paragraph with no explicit line breaks at all, which is the case that most exercises the wrapper: it has to find the break points itself, and the resulting lines must each fit the budget exactly while the whole paragraph still reads as one.

A paragraph containing a word that is longer than any sensible column budget and therefore has to be split mid-word: pseudopseudohypoparathyroidismandthensomemoreletterstomakeitabsurdlylongindeed.

A paragraph of CJK text, where every character is two columns wide, so the wrapper cannot pack them the way it packs Latin words: 这是一段中文文本用来测试换行行为因为每个汉字都是两个显示列宽所以换行器不能像处理英文单词那样处理它。

A paragraph mixing both, 中文 and Latin words, so the width accounting has to be right across the boundary.

Short.

A paragraph with  multiple   consecutive   spaces   which   must   survive   verbatim because they are load-bearing inside preformatted content, even though the line has to wrap.
