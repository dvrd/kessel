// React's CommonJS entry picks a build by `process.env.NODE_ENV`. With
// `--define process.env.NODE_ENV='"production"'` the bundle must run the
// production build, and with `--minify` it must not carry the development one.
import React from 'react';

const element = React.createElement('p', { id: 'x' }, 'hello');
// The development build freezes every element it creates.
console.log(React.version, element.type, element.props.children, Object.isFrozen(element));

export const version = React.version;
export const frozen = Object.isFrozen(element);
export const count = React.Children.count([1, 'b', null]);
