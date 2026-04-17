// CSS-in-JS patterns (styled-components/emotion style)
const Button = styled.button`
  color: ${props => props.primary ? 'white' : 'palevioletred'};
  font-size: 1em;
  margin: 1em;
  padding: 0.25em 1em;
  border: 2px solid palevioletred;
  border-radius: 3px;
`;

const styles = {
  container: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center'
  },
  button: css`
    background: transparent;
    &:hover { background: palevioletred; }
  `
};
