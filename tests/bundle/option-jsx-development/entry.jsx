const element = <main id="m"><span>a</span>{'b'}</main>;
console.log(element.type, element.dev, element.props.children.length, typeof element.source.lineNumber, element.source.fileName.endsWith('entry.jsx'));
