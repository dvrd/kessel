// Redux reducers con switch
const initialState = {
  loading: false,
  data: null,
  error: null
};

function userReducer(state = initialState, action) {
  switch (action.type) {
    case 'FETCH_USER_START':
      return { ...state, loading: true, error: null };
    case 'FETCH_USER_SUCCESS':
      return { ...state, loading: false, data: action.payload };
    case 'FETCH_USER_ERROR':
      return { ...state, loading: false, error: action.error };
    default:
      return state;
  }
}

export default userReducer;
